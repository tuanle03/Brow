import AppKit
import XCTest
@testable import Brow

final class DisplayKeyBindingsTests: XCTestCase {
    private let defaults: [ShortcutBinding] = [
        ShortcutBinding(action: .brightnessDown, keyCode: 122, modifiers: []),
        ShortcutBinding(action: .brightnessUp, keyCode: 120, modifiers: []),
        ShortcutBinding(action: .volumeMute, keyCode: 109, modifiers: []),
        ShortcutBinding(action: .volumeDown, keyCode: 103, modifiers: []),
        ShortcutBinding(action: .volumeUp, keyCode: 111, modifiers: []),
    ]

    private func match(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = [], bindings: [ShortcutBinding]? = nil, suspended: Bool = false) -> ShortcutMatch {
        ShortcutMatcher.match(keyCode: keyCode, flags: flags, bindings: bindings ?? defaults, suspended: suspended)
    }

    func testBareF1MatchesBrightnessDown() {
        XCTAssertEqual(match(122), .action(.brightnessDown, fine: false))
    }

    func testAllDefaultKeysMatch() {
        XCTAssertEqual(match(120), .action(.brightnessUp, fine: false))
        XCTAssertEqual(match(109), .action(.volumeMute, fine: false))
        XCTAssertEqual(match(103), .action(.volumeDown, fine: false))
        XCTAssertEqual(match(111), .action(.volumeUp, fine: false))
    }

    func testFunctionAndCapsLockFlagsAreIgnored() {
        XCTAssertEqual(match(122, [.function]), .action(.brightnessDown, fine: false))
        XCTAssertEqual(match(122, [.capsLock, .numericPad]), .action(.brightnessDown, fine: false))
    }

    func testOptionShiftGivesFineStep() {
        XCTAssertEqual(match(120, [.option, .shift]), .action(.brightnessUp, fine: true))
    }

    func testCommandF1DoesNotMatchBareF1Binding() {
        XCTAssertEqual(match(122, [.command]), .none)
    }

    func testOptionAloneDoesNotMatch() {
        XCTAssertEqual(match(122, [.option]), .none)
    }

    func testUnboundKeyPassesThrough() {
        XCTAssertEqual(match(0), .none)
    }

    func testSuspendedMatcherMatchesNothing() {
        XCTAssertEqual(match(122, suspended: true), .none)
    }

    func testReboundControlF1() {
        let bindings = [ShortcutBinding(action: .brightnessDown, keyCode: 122, modifiers: [.control])]
        XCTAssertEqual(match(122, bindings: bindings), .none)
        XCTAssertEqual(match(122, [.control], bindings: bindings), .action(.brightnessDown, fine: false))
        XCTAssertEqual(match(122, [.control, .option, .shift], bindings: bindings), .action(.brightnessDown, fine: true))
    }

    func testBindingModifiersAreNormalised() {
        let binding = ShortcutBinding(action: .brightnessDown, keyCode: 122, modifiers: [.function])
        XCTAssertEqual(binding.modifiers, [])
    }

    func testSwallowedKeyUpIsSwallowedOnce() {
        var tracker = SwallowedKeyTracker()
        tracker.noteSwallowedDown(122)
        XCTAssertTrue(tracker.shouldSwallowUp(122))
        XCTAssertFalse(tracker.shouldSwallowUp(122))
        XCTAssertFalse(tracker.shouldSwallowUp(120), "keyUp for a key we never swallowed passes through")
    }
}
