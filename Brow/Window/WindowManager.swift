//
//  WindowManager.swift
//  Brow
//

import AppKit
import SwiftUI

@MainActor
final class WindowManager {
    static let shared = WindowManager()

    private var windows: [NotchWindow] = []

    private init() {}

    /// Tear down any existing overlays and create a fresh `NotchWindow` for
    /// every screen that reports a hardware notch.
    func spawnNotchWindows() {
        teardown()

        let screens = ScreenHelper.notchedScreens()
        for screen in screens {
            // Always size the window to the maximum (open) footprint so the
            // SwiftUI content can animate within it without resizing AppKit.
            let openSize = CGSize(width: NotchSize.open.width, height: NotchSize.open.height)
            let frame = ScreenHelper.notchFrame(on: screen, size: openSize)

            let window = NotchWindow(contentRect: frame)
            window.contentView = NSHostingView(rootView: ContentView())
            window.setFrame(frame, display: true)
            window.orderFrontRegardless()

            windows.append(window)
        }
    }

    func teardown() {
        for window in windows {
            window.orderOut(nil)
        }
        windows.removeAll()
    }

    func handleScreenParametersChanged() {
        spawnNotchWindows()
    }
}
