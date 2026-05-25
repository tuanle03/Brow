//
//  CalendarEvent.swift
//  Brow
//

import Foundation

struct CalendarEvent: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let isAllDay: Bool
    /// Hex string ("#RRGGBB") describing the colour of the source calendar,
    /// so the view layer can tint a leading bar without importing AppKit.
    let calendarColorHex: String
    let location: String?
}
