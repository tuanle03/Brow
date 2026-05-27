import SwiftUI

/// The "AI" tab inside the expanded notch (PR #6 of the AI Sessions feature).
/// Mirrors the design previewed in the wireframe: a Sessions list (one row
/// per active Claude Code session, mascot reflects status) and a Pending
/// list (one row per queued PreToolUse, with Allow / Always / Deny actions).
///
/// Both lists drive directly off `ClaudeCodeStore`, so anything the sneak
/// peek does also updates the tab in sync.
struct AISessionsTabView: View {
    @ObservedObject private var store = ClaudeCodeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionHeader(icon: "rectangle.stack.fill",
                          title: "Sessions",
                          count: store.sessions.count,
                          accent: .cyan)
            if store.sessions.isEmpty {
                emptyState("No Claude Code sessions are running.")
            } else {
                VStack(spacing: 4) {
                    ForEach(orderedSessions, id: \.id) { sessionRow($0) }
                }
            }

            sectionHeader(icon: "list.bullet.indent",
                          title: "Pending",
                          count: store.pending.count,
                          accent: .pink)
            if store.pending.isEmpty {
                emptyState("Nothing waiting for approval.")
            } else {
                VStack(spacing: 4) {
                    ForEach(Array(store.pending.enumerated()), id: \.element.id) { idx, a in
                        pendingRow(index: idx + 1, approval: a)
                    }
                }
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var orderedSessions: [SessionState] {
        store.sessions.values.sorted { $0.lastEventAt > $1.lastEventAt }
    }

    // MARK: - Section header

    @ViewBuilder
    private func sectionHeader(icon: String, title: String, count: Int, accent: Color) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(accent)
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
            Text("\(count)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Capsule().fill(.white.opacity(0.08)))
        }
    }

    @ViewBuilder
    private func emptyState(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.4))
            .padding(.leading, 4)
    }

    // MARK: - Rows

    @ViewBuilder
    private func sessionRow(_ session: SessionState) -> some View {
        HStack(spacing: 8) {
            BrowMascot(state: mascotState(for: session), size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(displayName(for: session))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let lastTool = session.lastTool {
                    Text("last: \(lastTool)")
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            Spacer(minLength: 0)
            statusPill(for: session)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func pendingRow(index: Int, approval: PendingApproval) -> some View {
        HStack(spacing: 8) {
            Text("\(index)")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.white.opacity(0.45))
                .frame(width: 14, alignment: .trailing)
            Image(systemName: icon(for: approval.toolName))
                .font(.system(size: 10))
                .foregroundStyle(accent(for: approval.toolName))
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 1) {
                Text(approval.toolName)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.white)
                Text(approval.targetDescription)
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            HStack(spacing: 3) {
                quickButton("checkmark",        tint: .green, help: "Allow") {
                    store.decide(approval.id, as: .allow)
                }
                quickButton("checkmark.circle", tint: .cyan,  help: "Always allow") {
                    store.decide(approval.id, as: .allowAlways)
                }
                quickButton("xmark",            tint: .red,   help: "Deny") {
                    store.decide(approval.id, as: .deny)
                }
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.white.opacity(0.04))
        )
    }

    @ViewBuilder
    private func quickButton(_ icon: String,
                             tint: Color,
                             help: String,
                             action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(tint.opacity(0.18))
                )
        }
        .buttonStyle(.plain)
        .help(help)
    }

    @ViewBuilder
    private func statusPill(for session: SessionState) -> some View {
        let pendingForSession = store.pending.contains { $0.sessionID == session.id }
        let age = Date().timeIntervalSince(session.lastEventAt)
        if pendingForSession {
            pill("waiting", .pink)
        } else if age < 30 {
            pill("working", .cyan)
        } else {
            pill("idle " + formatIdle(age), .gray)
        }
    }

    @ViewBuilder
    private func pill(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.18)))
    }

    // MARK: - Helpers

    private func mascotState(for session: SessionState) -> BrowMascot.MascotState {
        let pendingForSession = store.pending.contains { $0.sessionID == session.id }
        let age = Date().timeIntervalSince(session.lastEventAt)
        if pendingForSession { return .attention }
        if age < 30 { return .working }
        return .idle
    }

    private func displayName(for session: SessionState) -> String {
        if let dir = session.projectDirectory,
           let last = dir.split(separator: "/").last {
            return String(last)
        }
        return String(session.id.prefix(8))
    }

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

    private func formatIdle(_ s: TimeInterval) -> String {
        if s < 60 { return "\(Int(s))s" }
        if s < 3600 { return "\(Int(s / 60))m" }
        return "\(Int(s / 3600))h"
    }
}

#Preview {
    AISessionsTabView()
        .frame(width: 460, height: 360)
        .padding(28)
        .background(Color.black)
}
