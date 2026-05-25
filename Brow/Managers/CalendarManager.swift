//
//  CalendarManager.swift
//  Brow
//
//  Wraps EventKit. Requests full-access on first launch, publishes the
//  current authorization status and a list of the next upcoming events
//  (today through 7 days ahead). Refreshes on EKEventStoreChanged and every
//  60s as a safety net.
//
//  Requires `NSCalendarsFullAccessUsageDescription` in Info.plist — set in
//  Xcode via the target's Info tab.
//

import AppKit
import EventKit
import Foundation
import Observation

@MainActor
@Observable
final class CalendarManager {
    static let shared = CalendarManager()

    private(set) var authorizationStatus: EKAuthorizationStatus
    private(set) var upcomingEvents: [CalendarEvent] = []

    @ObservationIgnored private let store = EKEventStore()
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var storeChangeObserver: NSObjectProtocol?

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
    }

    func start() {
        Task { @MainActor in
            await requestAccess()
            if authorizationStatus == .fullAccess {
                refreshEvents()
                startObserving()
                startPeriodicRefresh()
            }
        }
    }

    func stop() {
        refreshTask?.cancel()
        refreshTask = nil
        if let storeChangeObserver {
            NotificationCenter.default.removeObserver(storeChangeObserver)
        }
        storeChangeObserver = nil
    }

    // MARK: - Permission

    private func requestAccess() async {
        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = granted ? .fullAccess : .denied
        } catch {
            authorizationStatus = .denied
        }
    }

    // MARK: - Refresh

    private func refreshEvents() {
        let calendars = store.calendars(for: .event)
        guard !calendars.isEmpty else {
            upcomingEvents = []
            return
        }

        let now = Date()
        let weekAhead = Calendar.current.date(byAdding: .day, value: 7, to: now) ?? now
        let predicate = store.predicateForEvents(
            withStart: now,
            end: weekAhead,
            calendars: calendars
        )

        let mapped: [CalendarEvent] = store.events(matching: predicate)
            .sorted { $0.startDate < $1.startDate }
            .prefix(10)
            .map { ek in
                let hex = NSColor(cgColor: ek.calendar.cgColor)?.hexString() ?? "#888888"
                return CalendarEvent(
                    id: ek.eventIdentifier ?? UUID().uuidString,
                    title: ek.title ?? "",
                    startDate: ek.startDate,
                    endDate: ek.endDate,
                    isAllDay: ek.isAllDay,
                    calendarColorHex: hex,
                    location: ek.location
                )
            }
        upcomingEvents = mapped
    }

    private func startObserving() {
        storeChangeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged,
            object: store,
            queue: .main
        ) { _ in
            Task { @MainActor in
                CalendarManager.shared.refreshEvents()
            }
        }
    }

    private func startPeriodicRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                guard !Task.isCancelled else { return }
                self?.refreshEvents()
            }
        }
    }
}
