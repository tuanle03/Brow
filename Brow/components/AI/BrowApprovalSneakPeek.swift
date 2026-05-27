import SwiftUI

/// The horizontal "speech bubble" that pops out below the notch whenever
/// Claude Code's hook is waiting on the user. Drives directly off
/// `ClaudeCodeStore`'s pending queue — the head of the queue is rendered;
/// resolving it auto-cycles to the next one. PR #5 of the AI Sessions feature.
struct BrowApprovalSneakPeek: View {
    @ObservedObject private var store = ClaudeCodeStore.shared

    var body: some View {
        if let current = store.pending.first {
            content(for: current, queueIndex: 1, queueTotal: store.pending.count)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .opacity.combined(with: .scale(scale: 0.96, anchor: .top))
                    )
                )
                .id(current.id)
        }
    }

    @ViewBuilder
    private func content(for current: PendingApproval, queueIndex: Int, queueTotal: Int) -> some View {
        HStack(spacing: 10) {
            BrowMascot(state: .attention, size: 28)
                .padding(.leading, 2)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Image(systemName: toolIcon(for: current.toolName))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(toolAccent(for: current.toolName))
                    Text(toolLabel(for: current.toolName))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                    if let session = current.sessionID {
                        Text("·").foregroundStyle(.white.opacity(0.35))
                        Text(String(session.prefix(6)))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                    }
                }
                Text(current.targetDescription)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                button("Allow",  "⌘↵",  .green,  prominent: true) {
                    store.decide(current.id, as: .allow)
                }
                button("Always", "⌘⇧↵", .cyan, prominent: false) {
                    store.decide(current.id, as: .allowAlways)
                }
                button("Deny",   "⌘⎋",  .red, prominent: false) {
                    store.decide(current.id, as: .deny)
                }
            }

            if queueTotal > 1 {
                Text("\(queueIndex)/\(queueTotal)")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .padding(.horizontal, 5).padding(.vertical, 2)
                    .background(Capsule().fill(.white.opacity(0.08)))
            }
        }
        .padding(.vertical, 8).padding(.horizontal, 10)
        .frame(maxWidth: 540, minHeight: 50)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [.purple.opacity(0.6), .cyan.opacity(0.6), .pink.opacity(0.6)],
                                startPoint: .topLeading, endPoint: .bottomTrailing
                            ),
                            lineWidth: 0.8
                        )
                )
                .shadow(color: .black.opacity(0.6), radius: 14, x: 0, y: 6)
        )
    }

    @ViewBuilder
    private func button(_ label: String,
                        _ shortcut: String,
                        _ tint: Color,
                        prominent: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(label)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(prominent ? .black : .white)
                Text(shortcut)
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundStyle(prominent ? .black.opacity(0.55) : .white.opacity(0.5))
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 7).padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(tint.opacity(prominent ? 0 : 0.45), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Per-tool styling

    private func toolLabel(for toolName: String) -> String {
        switch toolName {
        case "Edit":  return "Edit"
        case "Write": return "Write"
        case "Bash":  return "Bash"
        case "Read":  return "Read"
        default:      return toolName
        }
    }
    private func toolIcon(for toolName: String) -> String {
        switch toolName {
        case "Edit":  return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash":  return "terminal"
        case "Read":  return "doc.text"
        default:      return "wand.and.rays"
        }
    }
    private func toolAccent(for toolName: String) -> Color {
        switch toolName {
        case "Edit":  return .yellow
        case "Write": return .orange
        case "Bash":  return .red
        case "Read":  return .blue
        default:      return .gray
        }
    }
}

#Preview("Approval sneak peek", traits: .sizeThatFitsLayout) {
    BrowApprovalSneakPeek()
        .padding(28)
        .background(Color.black)
        .onAppear {
            // Seed the shared store so the preview shows something
            Task { @MainActor in
                let payload = PreToolUsePayload(
                    sessionID: "preview-abc12345",
                    toolName: "Edit",
                    toolInput: ["file_path": .string("src/components/Login.tsx")],
                    projectDirectory: nil,
                    cwd: nil
                )
                _ = Task.detached {
                    _ = await ClaudeCodeStore.shared.handlePreToolUse(payload, rawJSON: "{}")
                }
            }
        }
}
