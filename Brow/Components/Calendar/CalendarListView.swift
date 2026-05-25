//
//  CalendarListView.swift
//  Brow
//
//  Compact stack of up to N upcoming events with a coloured leading bar per
//  source calendar. Falls back to a friendly status row when access has not
//  yet been granted or no events are scheduled.
//

import EventKit
import SwiftUI

struct CalendarListView: View {
    let events: [CalendarEvent]
    let authStatus: EKAuthorizationStatus
    var maxRows: Int = 3

    var body: some View {
        if events.isEmpty {
            statusRow
        } else {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(events.prefix(maxRows)) { event in
                    row(for: event)
                }
            }
        }
    }

    private func row(for event: CalendarEvent) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(Color(hex: event.calendarColorHex))
                .frame(width: 2.5)
                .frame(maxHeight: 22)

            VStack(alignment: .leading, spacing: 0) {
                Text(event.title.isEmpty ? "Untitled" : event.title)
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(timeLabel(for: event))
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 6) {
            Image(systemName: "calendar")
                .font(.caption)
                .foregroundStyle(.white.opacity(0.5))
            Text(statusText)
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
            Spacer(minLength: 0)
        }
    }

    private var statusText: String {
        switch authStatus {
        case .notDetermined: return "Requesting calendar access…"
        case .denied: return "Calendar access denied"
        case .restricted: return "Calendar access restricted"
        case .writeOnly: return "Calendar is write-only"
        case .fullAccess, .authorized: return "No upcoming events"
        @unknown default: return "Calendar unavailable"
        }
    }

    private func timeLabel(for event: CalendarEvent) -> String {
        if event.isAllDay {
            return "\(relativeDay(event.startDate)) · All day"
        }
        let time = Self.timeFormatter.string(from: event.startDate)
        return "\(relativeDay(event.startDate)) · \(time)"
    }

    private func relativeDay(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInTomorrow(date) { return "Tomorrow" }
        return Self.dayFormatter.string(from: date)
    }

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE"
        return f
    }()
}
