import AppKit
import KeyboardShortcuts
import Carbon.HIToolbox
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

/// Review finding C1: `KeyboardShortcuts.Name(default:)` and the Settings
/// recorder register Carbon global hotkeys, which swallow F1/F2/F10-F12
/// system-wide whenever Brow's event tap is not the one taking them.
final class DisplayKeyCarbonGuardTests: XCTestCase {
    override func tearDown() {
        DisplayKeyAction.allCases.forEach { KeyboardShortcuts.reset($0.shortcutName) }
        super.tearDown()
    }

    /// RegisterEventHotKey fails with eventHotKeyExistsErr if this process already owns the combo.
    private func canRegisterCarbonHotKey(keyCode: Int, carbonModifiers: Int) -> Bool {
        var ref: EventHotKeyRef?
        let id = EventHotKeyID(signature: OSType(0x42524F57), id: 4242)
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(carbonModifiers), id, GetApplicationEventTarget(), 0, &ref)
        if let ref { UnregisterEventHotKey(ref) }
        return status == noErr
    }

    func testDefaultBindingsAreNotCarbonHotKeys() {
        DisplayKeyCarbonGuard.install()
        for code in [122, 120, 109, 103, 111] {
            XCTAssertTrue(canRegisterCarbonHotKey(keyCode: code, carbonModifiers: 0), "keyCode \(code) is held by a Carbon hotkey")
        }
    }

    func testRecordedBindingIsNotACarbonHotKey() {
        DisplayKeyCarbonGuard.install()
        KeyboardShortcuts.setShortcut(.init(.f1, modifiers: [.control]), for: .displayBrightnessDown)
        XCTAssertTrue(canRegisterCarbonHotKey(keyCode: 122, carbonModifiers: 4096), "⌃F1 was registered as a Carbon hotkey after recording")
    }

    func testBindingCacheTracksRecordedShortcut() {
        DisplayKeyCarbonGuard.install()
        XCTAssertEqual(ShortcutMatcher.currentBindings().first { $0.action == .brightnessDown }?.modifiers, [])
        KeyboardShortcuts.setShortcut(.init(.f1, modifiers: [.control]), for: .displayBrightnessDown)
        XCTAssertEqual(ShortcutMatcher.currentBindings().first { $0.action == .brightnessDown }?.modifiers, [.control])
    }
}
