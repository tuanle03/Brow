//
//  SettingsView.swift
//  Brow
//

import SwiftUI

enum SettingsTab: String, CaseIterable, Identifiable, Hashable {
    case general
    case appearance
    case media
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .media: "Media"
        case .about: "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .media: "play.rectangle"
        case .about: "info.circle"
        }
    }
}

struct SettingsView: View {
    @State private var selection: SettingsTab = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsTab.allCases, selection: $selection) { tab in
                NavigationLink(value: tab) {
                    Label(tab.title, systemImage: tab.symbol)
                }
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
            .navigationTitle("Brow")
        } detail: {
            ScrollView {
                detail(for: selection)
                    .padding(24)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 480, minHeight: 360)
        }
    }

    @ViewBuilder
    private func detail(for tab: SettingsTab) -> some View {
        switch tab {
        case .general: GeneralSettingsView()
        case .appearance: AppearanceSettingsView()
        case .media: MediaSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

private struct GeneralSettingsView: View {
    var body: some View {
        Form {
            Section("General") {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AppearanceSettingsView: View {
    var body: some View {
        Form {
            Section("Appearance") {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MediaSettingsView: View {
    var body: some View {
        Form {
            Section("Media") {
                Text("Coming soon")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct AboutSettingsView: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "sparkles")
                .resizable()
                .scaledToFit()
                .frame(width: 64, height: 64)
                .foregroundStyle(.tint)
            Text("Brow")
                .font(.largeTitle.bold())
            Text("Phase 0 · Foundation")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 32)
    }
}
