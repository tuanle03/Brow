//
//  DisplayControlCenter.swift
//  Brow
//
//  Owns the external-display list, rebuilds it on hot-plug and wake, and is
//  the production DisplayControlEnvironment for the router.
//

import AppKit
import Combine
import Defaults

/// C callback — a nonisolated free function, since C function pointers
/// cannot carry actor isolation.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { DisplayControlCenter.shared.scheduleRebuild(after: 1) }
    }
}

@MainActor
final class DisplayControlCenter: ObservableObject, DisplayControlEnvironment {
    static let shared = DisplayControlCenter()

    @Published private(set) var displays: [ExternalDisplay] = []
    /// Normalised names of HDMI/DP audio devices, for the Settings status column.
    @Published private(set) var displayAudioNames: Set<String> = []

    private(set) lazy var router = DisplayControlRouter(environment: self)

    private let dimmer = GammaDimmer(applier: CoreGraphicsGammaApplier())
    private let ddcQueue = DispatchQueue(label: "Brow.DisplayControl.DDC", qos: .userInitiated)
    private var isRunning = false
    private var rebuildGeneration = 0
    private var rebuildWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // IOAVService handles go stale across sleep; the bus needs a moment after wake.
            MainActor.assumeIsolated { DisplayControlCenter.shared.scheduleRebuild(after: 2) }
        }
        rebuild()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, nil)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        rebuildWorkItem?.cancel()
        dimmer.restoreAll()
        displays = []
    }

    func scheduleRebuild(after delay: TimeInterval) {
        guard isRunning else { return }
        rebuildWorkItem?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { DisplayControlCenter.shared.rebuild() } }
        rebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        ddcQueue.async {
            let ids = DisplayRegistry.externalDisplayIDs()
            let matches = DisplayRegistry.match(displayIDs: ids)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = DisplayControlCenter.shared
                    guard center.isRunning, center.rebuildGeneration == generation else { return }
                    center.install(displayIDs: ids, matches: matches)
                }
            }
        }
    }

    private func install(displayIDs: [CGDirectDisplayID], matches: [CGDirectDisplayID: Arm64DDCTransport]) {
        dimmer.restoreAll()
        let levels = Defaults[.externalDisplayLevels]
        let queue = ddcQueue

        displays = displayIDs.map { id in
            let uuid = Self.uuid(for: id)
            let channel = matches[id].map { DDCChannel(transport: $0) }
            let brightnessWriter = channel.map { DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: $0, executor: { queue.async(execute: $0) }) }
            let volumeWriter = channel.map { DDCWriteCoalescer(vcp: DDCVCP.volume, channel: $0, executor: { queue.async(execute: $0) }) }

            let display = ExternalDisplay(
                id: id, uuid: uuid, name: Self.name(for: id),
                brightnessWriter: brightnessWriter, volumeWriter: volumeWriter,
                brightness: levels[ExternalDisplay.levelKey(uuid: uuid, kind: .brightness)] ?? 0.5,
                volume: levels[ExternalDisplay.levelKey(uuid: uuid, kind: .volume)] ?? 0.5,
                softwareLevel: levels[ExternalDisplay.levelKey(uuid: uuid, kind: .software)] ?? 1
            )
            for writer in [brightnessWriter, volumeWriter].compactMap({ $0 }) {
                writer.onResult = { [weak display] ok in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            display?.recordWriteResult(ok)
                            DisplayControlCenter.shared.objectWillChange.send()
                        }
                    }
                }
            }
            if !display.ddcAvailable && display.softwareLevel < 1 {
                dimmer.setLevel(display.softwareLevel, for: id)
            }
            if let channel {
                readInitialLevels(of: display, over: channel)
            }
            return display
        }
        displayAudioNames = Set(CoreAudioOutputs.displayAudioDeviceNames().map(ExternalDisplay.normalizedName))
        print("🔍 [DisplayControl] " + displays.map { "\($0.name) [\($0.ddcAvailable ? "ddc" : "gamma")]" }.joined(separator: ", "))
    }

    private func readInitialLevels(of display: ExternalDisplay, over channel: DDCChannel) {
        let name = display.name
        ddcQueue.async { [weak display] in
            let brightness = channel.read(vcp: DDCVCP.brightness)
            let volume = channel.read(vcp: DDCVCP.volume)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    display?.applyInitialReadings(brightness: brightness, volume: volume)
                    print("🔍 [DisplayControl] \(name) brightness=\(String(describing: brightness)) volume=\(String(describing: volume))")
                }
            }
        }
    }

    // MARK: - Display identity

    private static func uuid(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return "\(id)" }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    private static func name(for id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { screenNumber($0) == id }?.localizedName ?? "Display \(id)"
    }

    private static func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - DisplayControlEnvironment

    func displayUnderCursor() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }.flatMap(Self.screenNumber)
    }

    func externalDisplays() -> [ExternalDisplay] { displays }

    func defaultAudioOutput() -> AudioOutputInfo? { CoreAudioOutputs.defaultOutput() }

    func applyGamma(level: Double, to displayID: CGDirectDisplayID) {
        dimmer.setLevel(level, for: displayID)
    }

    func persistLevel(_ value: Double, key: String) {
        Defaults[.externalDisplayLevels][key] = value
    }

    func showHUD(_ type: SneakContentType, value: Double) {
        BrowViewCoordinator.shared.toggleSneakPeek(status: true, type: type, value: CGFloat(value), force: true)
    }

    func adjustBuiltinBrightness(delta: Float) {
        BrightnessManager.shared.setRelative(delta: delta)
    }

    func adjustSystemVolume(up: Bool, fine: Bool) {
        let divisor: Float = fine ? 4 : 1
        if up {
            VolumeManager.shared.increase(stepDivisor: divisor)
        } else {
            VolumeManager.shared.decrease(stepDivisor: divisor)
        }
    }

    func toggleSystemMute() {
        VolumeManager.shared.toggleMuteAction()
    }
}
