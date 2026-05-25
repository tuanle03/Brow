//
//  ScreenHelper.swift
//  Brow
//

import AppKit

enum ScreenHelper {
    /// All currently connected screens that report a top safe-area inset,
    /// which on macOS 12+ identifies built-in displays with a hardware notch.
    static func notchedScreens() -> [NSScreen] {
        NSScreen.screens.filter { $0.safeAreaInsets.top > 0 }
    }

    /// Frame (in global screen coordinates, bottom-left origin) for an overlay
    /// window of the given `size` pinned to the top-center of `screen`.
    static func notchFrame(on screen: NSScreen, size: CGSize) -> NSRect {
        let screenFrame = screen.frame
        let originX = screenFrame.midX - size.width / 2
        let originY = screenFrame.maxY - size.height
        return NSRect(x: originX, y: originY, width: size.width, height: size.height)
    }
}
