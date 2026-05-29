import Defaults
import SwiftUI

/// Debug + control surface for the AI Sessions feature.
/// - Section 1: bridge status (start/stop/restart, event counter)
/// - Section 2: Claude Code hook installer (writes ~/.brow/hooks + edits
///   ~/.claude/settings.json), with sibling-hook warning if Masko or other
///   tools already own the same hook point.
/// - Section 3: panel preferences (sound effects on/off).
/// - Section 4: last received event payload, for end-to-end smoke testing.
///
/// Future PRs reorganise this once the notch UI lands — for now the panel
/// stays diagnostic-flavoured.
struct AISettingsView: View {
    @ObservedObject private var bridge = ClaudeCodeBridge.shared
    @ObservedObject private var store = ClaudeCodeStore.shared

    @State private var installState: ClaudeCodeHookInstaller.InstallationState = .notInstalled
    @State private var hookError: String?
    @Default(.aiSoundEffectsEnabled) private var soundEffectsEnabled

    var body: some View {
        Form {
            bridgeSection
            hooksSection
            preferencesSection
            queueSection
            rulesSection
            lastEventSection
        }
        .formStyle(.grouped)
        .onAppear { refreshInstallState() }
    }

    // MARK: - Preferences

    @ViewBuilder
    private var preferencesSection: some View {
        Section {
            Toggle("Play sound effects", isOn: $soundEffectsEnabled)
                .toggleStyle(.switch)
                .onChange(of: soundEffectsEnabled) { _, newValue in
                    // Preview the chosen sound so the user hears what
                    // they're opting into — only when turning on.
                    if newValue { AISoundEffects.play(.notification) }
                }
        } header: {
            Text("Panel preferences")
        } footer: {
            Text("Plays a short macOS system sound when a permission request arrives, a notification toast pops, or a row is clicked.")
        }
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
                .disabled(!isInstalled)

                Spacer()

                Button("Refresh") { refreshInstallState() }
            }

            DisclosureGroup("Details") {
                LabeledContent("Claude settings") {
                    Text(ClaudeCodeHookInstaller.claudeSettingsPath)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                }
                LabeledContent("Hook command") {
                    Text(ClaudeCodeHookInstaller.hookCommand)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(3)
                        .truncationMode(.middle)
                }
            }
        } header: {
            Text("Claude Code hooks")
        } footer: {
            Text("Installing adds a PermissionRequest + Notification entry to ~/.claude/settings.json that pipes hook payloads into the local Brow bridge over loopback. Uninstall removes only Brow's entries — your other hooks are left untouched.")
        }
    }

    private var installStateIcon: String {
        switch installState {
        case .installed:                return "checkmark.seal.fill"
        case .installedWithSiblings:    return "checkmark.seal"
        case .notInstalled:             return "circle"
        }
    }

    private var installStateTint: Color {
        switch installState {
        case .installed:                return .green
        case .installedWithSiblings:    return .yellow
        case .notInstalled:             return .secondary
        }
    }

    private var installStateTitle: String {
        switch installState {
        case .installed:                return "Hooks installed"
        case .installedWithSiblings:    return "Hooks installed (with siblings)"
        case .notInstalled:             return "Hooks not installed"
        }
    }

    private var installButtonLabel: String {
        switch installState {
        case .notInstalled:             return "Install Hooks"
        default:                        return "Reinstall"
        }
    }

    private var isInstalled: Bool {
        switch installState {
        case .installed, .installedWithSiblings: return true
        case .notInstalled: return false
        }
    }

    private func refreshInstallState() {
        installState = ClaudeCodeHookInstaller.currentState()
    }

    // MARK: - Approval queue (debug surface for PR #3 — real sneak peek in PR #5)

    @ViewBuilder
    private var queueSection: some View {
        Section {
            if store.pending.isEmpty {
                Text("No tool calls waiting for approval.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.pending) { approval in
                    pendingRow(approval)
                }
            }

            if !store.recentlyResolved.isEmpty {
                Divider()
                HStack {
                    Text("Recent")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Clear") { store.clearRecentlyResolved() }
                        .controlSize(.small)
                }
                ForEach(store.recentlyResolved) { resolved in
                    resolvedRow(resolved)
                }
            }

            HStack(spacing: 8) {
                Button("Allow head") { store.decideHead(as: .allow) }
                    .disabled(store.pending.isEmpty)
                Button("Always allow head") { store.decideHead(as: .allowAlways) }
                    .disabled(store.pending.isEmpty)
                Button("Deny head") { store.decideHead(as: .deny) }
                    .disabled(store.pending.isEmpty)
                Spacer()
                Text("\(store.pending.count) waiting / \(store.sessions.count) session\(store.sessions.count == 1 ? "" : "s")")
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Pending approvals")
        } footer: {
            Text("Each PermissionRequest from Claude Code blocks here until you decide (max ~55s before Brow falls back to Claude Code's own dialog). Resolved or timed-out requests are kept under Recent so you can review prompts you missed.")
        }
    }

    @ViewBuilder
    private func resolvedRow(_ resolved: ResolvedApproval) -> some View {
        let a = resolved.approval
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Circle().fill(resolved.statusTint).frame(width: 6, height: 6)
            Text(a.toolName)
                .font(.callout.weight(.medium))
            Text(a.targetDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Text(resolved.statusLabel)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(resolved.statusTint)
            Text(resolved.resolvedAt, style: .relative)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func pendingRow(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(approval.toolName)
                    .font(.body.weight(.semibold))
                if let session = approval.sessionID {
                    Text("session \(String(session.prefix(8)))")
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(approval.receivedAt, style: .relative)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(approval.targetDescription)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 6) {
                Button("Allow")        { store.decide(approval.id, as: .allow) }
                Button("Always allow") { store.decide(approval.id, as: .allowAlways) }
                Button("Deny", role: .destructive) { store.decide(approval.id, as: .deny) }
            }
            .controlSize(.small)
        }
        .padding(.vertical, 4)
    }

    // MARK: - Saved "Always allow" rules

    @ViewBuilder
    private var rulesSection: some View {
        Section {
            if store.rules.isEmpty {
                Text("No saved \"always allow\" rules.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.rules) { rule in
                    HStack {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(rule.toolName)
                                .font(.body.monospaced())
                            Text(rule.argMatcher ?? "(any arguments)")
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(rule.decision.rawValue)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(rule.decision == .allow ? .green : .red)
                        Button("Remove", role: .destructive) {
                            store.removeRule(rule)
                        }
                        .controlSize(.small)
                    }
                }
            }
            if let err = store.lastRuleError {
                Text(err).font(.callout).foregroundStyle(.red)
            }
        } header: {
            Text("Saved rules")
        } footer: {
            Text("Rules live at \(PermissionRule.rulesPath). Picking \"Always allow\" on a pending entry adds a tool-name match here.")
        }
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
