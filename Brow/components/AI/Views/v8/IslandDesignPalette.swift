//
//  IslandDesignPalette.swift
//  Brow
//
//  Task 2.1: the v8 notch UI's design palette, ported from the
//  open-vibe-island reference (IslandDesignPalette.swift / V6ClosedPillShape.swift).
//  Downstream v8 views (2.2/2.4/2.5/2.6) build on `V6Palette`,
//  `IslandStatus.tint(for:)`, and `AgentTool.brandColor`.
//

import SwiftUI

/// The notch's two base surfaces: near-black ink for the shell, warm paper
/// for content that needs to read on top of it.
enum V6Palette {
    static let ink = Color(hex: "0D0D0F")
    static let paper = Color(hex: "F1EAD9")
}

/// Per-phase accent colors for the v8 island — the tint that communicates a
/// session's state at a glance (running blue, needs-approval red, etc.).
enum IslandStatus {
    static let running = Color(hex: "6EA7FF")
    static let waitingForApproval = Color(hex: "F4A4A4")
    static let waitingForAnswer = Color(hex: "FFD58A")
    static let completed = Color(hex: "6FB982")
    static let waiting = Color(hex: "E7A762")

    static func tint(for phase: SessionPhase) -> Color {
        switch phase {
        case .running: running
        case .waitingForApproval: waitingForApproval
        case .waitingForAnswer: waitingForAnswer
        case .completed: completed
        }
    }
}

extension AgentTool {
    /// The tool's brand color, resolved from `brandColorHex`.
    var brandColor: Color { Color(hex: brandColorHex) }
}

// MARK: - Color(hex:)

// Brow has no existing hex→Color initializer (checked `Color+AccentColor.swift`
// and grepped the codebase for `init(hex`) — this is the first one, scoped to
// this file so downstream v8 views can keep using it.
extension Color {
    init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = Double((value >> 16) & 0xFF) / 255
        let g = Double((value >> 8) & 0xFF) / 255
        let b = Double(value & 0xFF) / 255
        self.init(red: r, green: g, blue: b)
    }
}
