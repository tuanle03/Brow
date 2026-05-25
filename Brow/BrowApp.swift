//
//  BrowApp.swift
//  Brow
//

import SwiftUI

@main
struct BrowApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra("Brow", systemImage: "sparkles") {
            StatusBarMenu()
        }

        Settings {
            SettingsView()
        }
    }
}
