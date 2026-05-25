//
//  StatusBarMenu.swift
//  Brow
//

import SwiftUI

struct StatusBarMenu: View {
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button("Open Settings…") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: .command)

        Divider()

        Button("Quit Brow") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: .command)
    }
}
