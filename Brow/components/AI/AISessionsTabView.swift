import SwiftUI

/// The "AI" tab inside the expanded notch. Single-purpose layout: when
/// Claude Code is waiting on the user, we surface only the prompt — tool
/// info + path + Allow / Suggestion / Deny buttons. No sessions list, no
/// recent log, no extra chrome. When nothing is waiting we show a small
/// idle state.
struct AISessionsTabView: View {
    @ObservedObject private var store = ClaudeCodeStore.shared

    var body: some View {
        Group {
            if let current = store.pending.first {
                approvalCard(current,
                             queueIndex: 1,
                             queueTotal: store.pending.count)
                    .id(current.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
            } else if let toast = store.transientNotification {
                notificationCard(toast)
                    .id(toast.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .center)))
            } else {
                idleState
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.smooth(duration: 0.25), value: store.pending.first?.id)
        .animation(.smooth(duration: 0.25), value: store.transientNotification?.id)
    }

    // MARK: - Approval bubble (vertical layout, no truncation)

    @ViewBuilder
    private func approvalCard(_ approval: PendingApproval,
                              queueIndex: Int,
                              queueTotal: Int) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                BrowMascot(state: .attention, size: 36)

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: icon(for: approval.toolName))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(accent(for: approval.toolName))
                        Text(approval.toolName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                        if let session = approval.sessionID {
                            Text("·").foregroundStyle(.white.opacity(0.35))
                            Text(String(session.prefix(6)))
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                    Text(approval.targetDescription)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if queueTotal > 1 {
                    Text("\(queueIndex)/\(queueTotal)")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.6))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
            }

            HStack(spacing: 6) {
                actionButton("Allow", "⌘↵", .green, prominent: true) {
                    store.decide(approval.id, as: .allow)
                }
                ForEach(Array(approval.suggestions.enumerated()), id: \.element.id) { index, suggestion in
                    let shortcut = index == 0 ? "⌘⇧↵" : nil
                    actionButton(suggestion.displayLabel, shortcut, .cyan, prominent: false) {
                        store.decide(approval.id, as: .allowWith(suggestion))
                    }
                }
                actionButton("Deny", "⌘⎋", .red, prominent: false) {
                    store.decide(approval.id, as: .deny)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
        }
    }

    // MARK: - Notification bubble

    @ViewBuilder
    private func notificationCard(_ toast: TransientNotification) -> some View {
        HStack(alignment: .center, spacing: 12) {
            BrowMascot(state: toast.kind == .stopped ? .approved : .attention, size: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                Text(toast.body)
                    .font(.system(size: 13))
                    .foregroundStyle(.white)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.dismissTransientNotification()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(8)
                    .background(Circle().fill(.white.opacity(0.08)))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Idle state

    @ViewBuilder
    private var idleState: some View {
        HStack(spacing: 10) {
            BrowMascot(state: .idle, size: 28)
            Text("Nothing waiting.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    // MARK: - Buttons

    @ViewBuilder
    private func actionButton(_ label: String,
                              _ shortcut: String?,
                              _ tint: Color,
                              prominent: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Text(label)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(prominent ? .black : .white)
                    .lineLimit(1)
                if let shortcut {
                    Text(shortcut)
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(prominent ? .black.opacity(0.55) : .white.opacity(0.5))
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(prominent ? tint : tint.opacity(0.18))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(tint.opacity(prominent ? 0 : 0.45), lineWidth: 0.8)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Per-tool styling

    private func icon(for toolName: String) -> String {
        switch toolName {
        case "Edit":  return "pencil"
        case "Write": return "doc.badge.plus"
        case "Bash":  return "terminal"
        case "Read":  return "doc.text"
        default:      return "wand.and.rays"
        }
    }

    private func accent(for toolName: String) -> Color {
        switch toolName {
        case "Edit":  return .yellow
        case "Write": return .orange
        case "Bash":  return .red
        case "Read":  return .blue
        default:      return .gray
        }
    }
}

#Preview {
    AISessionsTabView()
        .frame(width: 460, height: 200)
        .padding(28)
        .background(Color.black)
}
