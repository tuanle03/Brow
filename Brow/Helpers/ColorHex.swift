//
//  ColorHex.swift
//  Brow
//
//  Lightweight hex <-> Color/NSColor conversions used by the calendar widget
//  to surface per-calendar tints without dragging AppKit into models.
//

import AppKit
import SwiftUI

extension NSColor {
    /// Produces a sRGB "#RRGGBB" string, ignoring alpha. Returns `nil` if the
    /// receiver can't be converted into sRGB (e.g. pattern colours).
    func hexString() -> String? {
        guard let rgb = usingColorSpace(.sRGB) else { return nil }
        let r = Int(round(rgb.redComponent * 255))
        let g = Int(round(rgb.greenComponent * 255))
        let b = Int(round(rgb.blueComponent * 255))
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

extension Color {
    /// Parses a "#RRGGBB" or "RRGGBB" string. Falls back to a neutral grey on
    /// malformed input so the UI never crashes on a bad string.
    init(hex: String) {
        let trimmed = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: trimmed).scanHexInt64(&int)
        guard trimmed.count == 6 else {
            self.init(red: 0.5, green: 0.5, blue: 0.5)
            return
        }
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        self.init(.sRGB, red: r, green: g, blue: b, opacity: 1)
    }
}
