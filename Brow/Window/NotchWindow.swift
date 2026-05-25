//
//  NotchWindow.swift
//  Brow
//

import AppKit

/// Borderless, non-activating NSPanel that floats above the menu bar so it can
/// render artwork directly over the hardware notch area.
final class NotchWindow: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        backgroundColor = .clear
        isOpaque = false
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true

        level = NSWindow.Level(
            rawValue: Int(CGWindowLevelForKey(.mainMenuWindow)) + 3
        )

        collectionBehavior = [
            .canJoinAllSpaces,
            .stationary,
            .fullScreenAuxiliary,
            .ignoresCycle
        ]
    }

    // The notch overlay never takes keyboard focus — apps below it keep focus.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
