//
//  BatteryActivityManager.swift
//  Brow
//
//  Listens to IOKit power-source notifications, publishes a current
//  `BatteryInfo` snapshot, and emits a charging sneak peek whenever AC power
//  is plugged in or unplugged.
//

import AppKit
import Foundation
import IOKit.ps
import Observation

@MainActor
@Observable
final class BatteryActivityManager {
    static let shared = BatteryActivityManager()

    private(set) var info: BatteryInfo = .placeholder

    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var lowPowerObserver: NSObjectProtocol?
    @ObservationIgnored private var lastPluggedState: Bool?

    private init() {}

    func start() {
        guard runLoopSource == nil else { return }
        refresh()

        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let manager = Unmanaged<BatteryActivityManager>
                .fromOpaque(context).takeUnretainedValue()
            Task { @MainActor in
                manager.refresh()
            }
        }

        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?
            .takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .defaultMode)
            runLoopSource = source
        }

        lowPowerObserver = NotificationCenter.default.addObserver(
            forName: .NSProcessInfoPowerStateDidChange,
            object: nil,
            queue: .main
        ) { _ in
            Task { @MainActor in
                BatteryActivityManager.shared.refresh()
            }
        }
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        }
        runLoopSource = nil
        if let lowPowerObserver {
            NotificationCenter.default.removeObserver(lowPowerObserver)
        }
        lowPowerObserver = nil
    }

    // MARK: - Private

    private func refresh() {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sourcesRaw = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue()
        else { return }

        let sources = sourcesRaw as [CFTypeRef]
        guard let source = sources.first,
              let descRaw = IOPSGetPowerSourceDescription(blob, source)?
                .takeUnretainedValue(),
              let desc = descRaw as? [String: Any]
        else { return }

        let currentCapacity = desc[kIOPSCurrentCapacityKey] as? Int ?? 0
        let maxCapacity = desc[kIOPSMaxCapacityKey] as? Int ?? 100
        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isPluggedIn = powerSource == kIOPSACPowerValue
        let timeToFullRaw = desc[kIOPSTimeToFullChargeKey] as? Int
        let timeToEmptyRaw = desc[kIOPSTimeToEmptyKey] as? Int

        let percentage = maxCapacity > 0
            ? Int((Double(currentCapacity) / Double(maxCapacity)) * 100)
            : currentCapacity

        let new = BatteryInfo(
            percentage: percentage,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            timeToFull: (timeToFullRaw ?? 0) > 0 ? timeToFullRaw : nil,
            timeToEmpty: (timeToEmptyRaw ?? 0) > 0 ? timeToEmptyRaw : nil,
            isLowPowerMode: ProcessInfo.processInfo.isLowPowerModeEnabled
        )

        // Only emit a sneak peek when the AC state transitions; the initial
        // snapshot just records `lastPluggedState` without triggering one.
        if let last = lastPluggedState, last != isPluggedIn {
            BrowViewCoordinator.shared.showSneakPeek(
                .charging(plugged: isPluggedIn, percentage: percentage)
            )
        }
        lastPluggedState = isPluggedIn

        info = new
    }
}
