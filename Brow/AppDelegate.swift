//
//  AppDelegate.swift
//  Brow
//

import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        Task { @MainActor in
            WindowManager.shared.spawnNotchWindows()
            MusicManager.shared.start()
            BatteryActivityManager.shared.start()
        }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(screenParametersChanged),
            name: NSApplication.didChangeScreenParametersNotification,
            object: nil
        )
    }

    @objc private func screenParametersChanged() {
        Task { @MainActor in
            WindowManager.shared.handleScreenParametersChanged()
        }
    }
}
