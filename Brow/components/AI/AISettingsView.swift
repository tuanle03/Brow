import SwiftUI

/// Debug + control surface for the AI Sessions feature.
/// - Section 1: bridge status (start/stop/restart, event counter)
/// - Section 2: Claude Code hook installer (writes ~/.brow/hooks + edits
///   ~/.claude/settings.json), with sibling-hook warning if Masko or other
///   tools already own the same hook point.
/// - Section 3: last received event payload, for end-to-end smoke testing.
///
/// Future PRs reorganise this once the notch UI lands — for now the panel
/// stays diagnostic-flavoured.
struct AISettingsView: View {
    @ObservedObject private var bridge = ClaudeCodeBridge.shared

    @State private var installState: ClaudeCodeHookInstaller.InstallationState = .notInstalled
    @State private var hookError: String?

    var body: some View {
        Form {
            bridgeSection
            hooksSection
            lastEventSection
        }
        .formStyle(.grouped)
        .onAppear { refreshInstallState() }
    }

    // MARK: - Bridge

    @ViewBuilder
    private var bridgeSection: some View {
        Section {
            HStack {
                Image(systemName: bridge.isListening ? "circle.fill" : "circle")
                    .foregroundStyle(bridge.isListening ? .green : .secondary)
                Text(bridge.isListening
                     ? "Listening on 127.0.0.1:\(ClaudeCodeBridge.port)"
                     : "Bridge not running")
                    .font(.body.monospaced())
            }
            if let error = bridge.lastError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }
            HStack {
                Button(bridge.isListening ? "Stop" : "Start") {
                    if bridge.isListening { bridge.stop() } else { bridge.start() }
                }
                Spacer()
                Text("Events received: \(bridge.totalEventsSeen)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Claude Code bridge")
        } footer: {
            Text("Brow listens for Claude Code hook events on this local port. Future updates will use it to surface tool-approval prompts in the notch.")
        }
    }

    // MARK: - Hook installation

    @ViewBuilder
    private var hooksSection: some View {
        Section {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: installStateIcon)
                    .foregroundStyle(installStateTint)
                Text(installStateTitle)
                    .font(.body.weight(.medium))
                Spacer()
            }

            if case .installedWithSiblings(let siblings) = installState {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Other tools also have a hook at PreToolUse / Notification — Claude Code will run them in parallel with Brow:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(siblings, id: \.self) { command in
                        Text(command)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
            }

            if let error = hookError {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
            }

            HStack {
                Button(installButtonLabel) {
                    do {
                        try ClaudeCodeHookInstaller.install()
                        hookError = nil
                    } catch {
                        hookError = error.localizedDescription
                    }
                    refreshInstallState()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isInstalled)

                Button("Uninstall") {
                    do {
                        try ClaudeCodeHookInstaller.uninstall()
                        hookError = nil
                    } catch {
                        hookError = error.localizedDescription
                    }
                    refreshInstallState()
                }
                .disabled(!isInstalledOrOrphaned)

                Spacer()

                Button("Refresh") { refreshInstallState() }
            }

            DisclosureGroup("Paths") {
                LabeledContent("Hook script") {
                    Text(ClaudeCodeHookInstaller.hookScriptPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Claude settings") {
                    Text(ClaudeCodeHookInstaller.claudeSettingsPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
            }
        } header: {
            Text("Claude Code hooks")
        } footer: {
            Text("Installing writes ~/.brow/hooks/brow-claude-hook and adds a PreToolUse + Notification entry to ~/.claude/settings.json. Uninstall removes only Brow's entries — your other hooks are left untouched.")
        }
    }

    private var installStateIcon: String {
        switch installState {
        case .installed:                return "checkmark.seal.fill"
        case .installedWithSiblings:    return "checkmark.seal"
        case .scriptOrphaned:           return "exclamationmark.triangle.fill"
        case .notInstalled:             return "circle"
        }
    }

    private var installStateTint: Color {
        switch installState {
        case .installed:                return .green
        case .installedWithSiblings:    return .yellow
        case .scriptOrphaned:           return .orange
        case .notInstalled:             return .secondary
        }
    }

    private var installStateTitle: String {
        switch installState {
        case .installed:                return "Hooks installed"
        case .installedWithSiblings:    return "Hooks installed (with siblings)"
        case .scriptOrphaned:           return "Hook script present, but settings.json doesn't reference it"
        case .notInstalled:             return "Hooks not installed"
        }
    }

    private var installButtonLabel: String {
        switch installState {
        case .notInstalled, .scriptOrphaned: return "Install Hooks"
        default: return "Reinstall"
        }
    }

    private var isInstalled: Bool {
        switch installState {
        case .installed, .installedWithSiblings: return true
        default: return false
        }
    }

    private var isInstalledOrOrphaned: Bool {
        installState != .notInstalled
    }

    private func refreshInstallState() {
        installState = ClaudeCodeHookInstaller.currentState()
    }

    // MARK: - Last event echo

    @ViewBuilder
    private var lastEventSection: some View {
        Section {
            if let last = bridge.lastEvent {
                LabeledContent("Hook") {
                    Text(last.hookName).font(.body.monospaced())
                }
                LabeledContent("Received") {
                    Text(last.receivedAt.formatted(date: .omitted, time: .standard))
                        .font(.body.monospaced())
                }
                DisclosureGroup("Raw JSON") {
                    ScrollView(.vertical, showsIndicators: true) {
                        Text(last.rawJSON)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.black.opacity(0.5))
                    )
                }
            } else {
                Text("No events received yet.")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Last event")
        } footer: {
            Text("Smoke-test from a terminal: curl -X POST -d '{\"hook_event_name\":\"PreToolUse\",\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"ls\"}}' http://127.0.0.1:\(ClaudeCodeBridge.port)/event")
                .font(.caption.monospaced())
        }
    }
}

#Preview {
    AISettingsView()
        .frame(width: 520, height: 640)
}
