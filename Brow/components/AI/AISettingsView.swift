import SwiftUI

/// Debug-only Settings panel for the AI Sessions feature. Wired up in this
/// initial bridge-skeleton PR so the user can verify the local HTTP server
/// is alive and inspect the raw payload Claude Code's hook posts. Subsequent
/// PRs replace this view with the real "AI Sessions" Settings tab (hook
/// installer, queue, etc.).
struct AISettingsView: View {
    @ObservedObject private var bridge = ClaudeCodeBridge.shared

    var body: some View {
        Form {
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
        .formStyle(.grouped)
    }
}

#Preview {
    AISettingsView()
        .frame(width: 520, height: 540)
}
