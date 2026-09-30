//
//  DisplayKeyBindings.swift
//  Brow
//
//  Matches raw keyDown events against the user's external-display bindings.
//  Plain F-keys from non-Apple keyboards arrive as keyDown (not NX media
//  keys), so matching happens here instead of via Carbon hotkeys.
//

import AppKit
import KeyboardShortcuts

enum DisplayKeyAction: CaseIterable, Equatable {
    case brightnessDown, brightnessUp, volumeMute, volumeDown, volumeUp

    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .brightnessDown: .displayBrightnessDown
        case .brightnessUp: .displayBrightnessUp
        case .volumeMute: .displayVolumeMute
        case .volumeDown: .displayVolumeDown
        case .volumeUp: .displayVolumeUp
        }
    }
}

struct ShortcutBinding: Equatable {
    let action: DisplayKeyAction
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags

    init(action: DisplayKeyAction, keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = ShortcutMatcher.normalize(modifiers)
    }

    init(action: DisplayKeyAction, shortcut: KeyboardShortcuts.Shortcut) {
        self.init(action: action, keyCode: shortcut.carbonKeyCode, modifiers: shortcut.modifiers)
    }
}

enum ShortcutMatch: Equatable {
    case none
    case action(DisplayKeyAction, fine: Bool)
}

enum ShortcutMatcher {
    /// F-keys carry `.function` (and sometimes `.numericPad`) on their own;
    /// Caps Lock must not change behaviour. Only these four count.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let fineModifiers: NSEvent.ModifierFlags = [.option, .shift]

    static func normalize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(relevantModifiers)
    }

    static func match(keyCode: Int, flags: NSEvent.ModifierFlags, bindings: [ShortcutBinding], suspended: Bool) -> ShortcutMatch {
        guard !suspended else { return .none }
        let modifiers = normalize(flags)
        for binding in bindings where binding.keyCode == keyCode && binding.modifiers == modifiers {
            return .action(binding.action, fine: false)
        }
        for binding in bindings where binding.keyCode == keyCode
            && !binding.modifiers.contains(fineModifiers)
            && binding.modifiers.union(fineModifiers) == modifiers {
            return .action(binding.action, fine: true)
        }
        return .none
    }

    /// Cached; see `DisplayKeyCarbonGuard`.
    static func currentBindings() -> [ShortcutBinding] {
        DisplayKeyCarbonGuard.bindings()
    }

    static func readBindings() -> [ShortcutBinding] {
        DisplayKeyAction.allCases.compactMap { action in
            KeyboardShortcuts.getShortcut(for: action.shortcutName).map { ShortcutBinding(action: action, shortcut: $0) }
        }
    }
}

/// Remembers swallowed keyDowns so the matching keyUp is swallowed too —
/// apps must never see a keyUp without its keyDown.
struct SwallowedKeyTracker {
    private var keyCodes = Set<Int>()

    mutating func noteSwallowedDown(_ keyCode: Int) {
        keyCodes.insert(keyCode)
    }

    mutating func shouldSwallowUp(_ keyCode: Int) -> Bool {
        keyCodes.remove(keyCode) != nil
    }
}

/// `KeyboardShortcuts` registers every named shortcut as a Carbon global
/// hotkey — on first touch of a `default:` and on every recording — which
/// would swallow F1/F2/F10-F12 system-wide even when Brow's event tap is not
/// the one handling them. These names are used for storage + recorder UI
/// only, so their Carbon registration is undone after every change. The
/// same change notification invalidates the cached bindings.
enum DisplayKeyCarbonGuard {
    private static let lock = NSLock()
    private static var observer: NSObjectProtocol?
    private static var cachedBindings: [ShortcutBinding]?

    static func install() {
        lock.lock()
        let needsObserver = observer == nil
        if needsObserver {
            observer = NotificationCenter.default.addObserver(
                forName: Notification.Name("KeyboardShortcuts_shortcutByNameDidChange"), object: nil, queue: nil
            ) { note in
                guard let name = note.userInfo?["name"] as? KeyboardShortcuts.Name,
                      DisplayKeyAction.allCases.contains(where: { $0.shortcutName == name }) else { return }
                lock.lock()
                cachedBindings = nil
                lock.unlock()
                disableAll()
            }
        }
        cachedBindings = nil
        lock.unlock()
        disableAll()
    }

    static func bindings() -> [ShortcutBinding] {
        lock.lock()
        if let cachedBindings {
            lock.unlock()
            return cachedBindings
        }
        lock.unlock()
        let fresh = ShortcutMatcher.readBindings()
        lock.lock()
        cachedBindings = fresh
        lock.unlock()
        return fresh
    }

    private static func disableAll() {
        KeyboardShortcuts.disable(DisplayKeyAction.allCases.map(\.shortcutName))
    }
}
