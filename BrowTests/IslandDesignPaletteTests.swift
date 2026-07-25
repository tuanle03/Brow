//
//  IslandDesignPaletteTests.swift
//  BrowTests
//
//  Task 2.1: locks the v8 design palette's exact colors so later view work
//  (2.2/2.4/2.5/2.6) can trust `V6Palette` and `IslandStatus` without
//  re-checking hex values.
//

import XCTest
import SwiftUI
@testable import Brow

final class IslandDesignPaletteTests: XCTestCase {
    private func assertHex(_ color: Color, _ hex: String, file: StaticString = #filePath, line: UInt = #line) {
        let ns = NSColor(color).usingColorSpace(.deviceRGB)!
        let expected = NSColor(hex: hex)
        XCTAssertEqual(ns.redComponent, expected.redComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(ns.greenComponent, expected.greenComponent, accuracy: 0.001, file: file, line: line)
        XCTAssertEqual(ns.blueComponent, expected.blueComponent, accuracy: 0.001, file: file, line: line)
    }

    func test_v6Palette_ink_and_paper_match_exact_hex() {
        assertHex(V6Palette.ink, "0D0D0F")
        assertHex(V6Palette.paper, "F1EAD9")
    }

    func test_islandStatus_named_colors_match_exact_hex() {
        assertHex(IslandStatus.running, "6EA7FF")
        assertHex(IslandStatus.waitingForApproval, "F4A4A4")
        assertHex(IslandStatus.waitingForAnswer, "FFD58A")
        assertHex(IslandStatus.completed, "6FB982")
        assertHex(IslandStatus.waiting, "E7A762")
    }

    func test_islandStatus_tint_maps_sessionPhase_to_named_colors() {
        assertHex(IslandStatus.tint(for: .running), "6EA7FF")
        assertHex(IslandStatus.tint(for: .waitingForApproval), "F4A4A4")
        assertHex(IslandStatus.tint(for: .waitingForAnswer), "FFD58A")
        assertHex(IslandStatus.tint(for: .completed), "6FB982")
    }

    func test_agentTool_brandColor_matches_brandColorHex() {
        assertHex(AgentTool.claudeCode.brandColor, "d97742")
        assertHex(AgentTool.codex.brandColor, "4aa3df")
    }
}

private extension NSColor {
    convenience init(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r = CGFloat((value >> 16) & 0xFF) / 255
        let g = CGFloat((value >> 8) & 0xFF) / 255
        let b = CGFloat(value & 0xFF) / 255
        self.init(deviceRed: r, green: g, blue: b, alpha: 1)
    }
}
