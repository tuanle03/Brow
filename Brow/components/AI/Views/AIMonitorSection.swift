import SwiftUI

/// Task list for the `.monitor` (and `.jump`) display mode. The first task
/// is rendered "highlighted" with the mascot + user prompt + status body
/// line; the rest collapse to a single row with a colored status dot.
/// Empty state mirrors the old `AISessionsTabView` "nothing waiting" copy
/// so existing users don't see a regression.
struct AIMonitorSection: View {
    let tasks: [AITask]

    var body: some View {
        if tasks.isEmpty {
            emptyState
        } else {
            // Wrap in a ScrollView so > ~3 sessions don't push the panel
            // past the open notch height (190pt) and get clipped by the
            // camera cutout at the top. The highlighted row stays pinned
            // at the top of the scroll content; older sessions scroll
            // into view.
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    ForEach(Array(tasks.enumerated()), id: \.element.id) { index, task in
                        if index == 0 {
                            highlightedRow(task)
                        } else {
                            collapsedRow(task)
                        }
                        if index < tasks.count - 1 {
                            Divider()
                                .overlay(Color.white.opacity(0.06))
                                .padding(.leading, index == 0 ? 0 : 24)
                        }
                    }
                }
                .padding(.vertical, 8)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            BrowMascot(state: .idle, size: 28)
            Text("Nothing waiting.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func highlightedRow(_ task: AITask) -> some View {
        HStack(alignment: .top, spacing: 12) {
            BrowMascot(state: mascotState(for: task.status), size: 30)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 3) {
                Text(task.titleLine)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)

                // Prefer "what AI is doing" over "what user just typed"
                // — short answers like "yes" / "Indigo / Violet" used to
                // dominate the row and read like the user's own echo.
                // Falls back to userPrompt only when no tool activity is
                // recorded yet (brand-new session).
                if let activity = task.lastToolActivity, !activity.isEmpty {
                    Text(activity)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                } else if let prompt = task.userPrompt, !prompt.isEmpty {
                    Text("You: \(prompt)")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                        .lineLimit(1)
                }

                if let body = task.status.bodyText {
                    Text(body)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(task.status.bodyColor)
                        .lineLimit(1)
                        .padding(.top, 1)
                }
            }

            Spacer(minLength: 8)

            tagPills(task)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
        .modifier(JumpOnTap(task: task))
    }

    private func collapsedRow(_ task: AITask) -> some View {
        HStack(spacing: 12) {
            Circle()
                .fill(task.status.dotColor)
                .frame(width: 8, height: 8)
            Text(task.titleLine)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(1)
            Spacer(minLength: 8)
            tagPills(task)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .modifier(JumpOnTap(task: task))
    }

    private func tagPills(_ task: AITask) -> some View {
        HStack(spacing: 6) {
            AITagPill(label: task.agentKind.displayName)
            AITagPill(label: task.terminalPillLabel)
            Text(task.timeAgoShort)
                .font(.system(size: 11))
                .foregroundStyle(.white.opacity(0.45))
                .padding(.leading, 2)
        }
    }

    private func mascotState(for status: AITaskStatus) -> BrowMascot.MascotState {
        switch status {
        case .pendingApproval, .askingQuestion: return .attention
        case .working:                          return .working
        case .done:                             return .approved
        case .idle:                             return .idle
        }
    }
}

/// Makes the whole row area clickable as a hand-cursor button that fires
/// `TerminalJumpService.jump(to:)`. Lifted into a modifier so both row
/// styles share the same hit target, hover background, and tooltip.
private struct JumpOnTap: ViewModifier {
    let task: AITask
    @State private var isHovering = false

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .background(
                Rectangle()
                    .fill(.white.opacity(isHovering ? 0.05 : 0))
                    .allowsHitTesting(false)
            )
            .onHover { hovering in
                isHovering = hovering
                if hovering {
                    NSCursor.pointingHand.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onTapGesture {
                TerminalJumpService.jump(to: task)
            }
            .help(jumpHelpText)
    }

    private var jumpHelpText: String {
        if let hint = task.terminalAppHint, !hint.isEmpty {
            return "Jump to \(hint)"
        }
        return "No terminal recorded for this session"
    }
}

private extension AITask {
    /// First line of the row. Prefer the project folder name — it stays
    /// stable across the whole session and reads like a real label
    /// ("Brow", "api-server"). The user's last prompt was the previous
    /// choice but it was too volatile: a short answer like "yes" or
    /// "Indigo / Violet" took over the row whenever the user replied to
    /// Claude. The activity subtitle (lastToolActivity) now carries the
    /// "what's happening" signal so the title doesn't need to.
    var titleLine: String {
        if let dir = projectDirectory, !dir.isEmpty {
            return (dir as NSString).lastPathComponent
        }
        if let prompt = userPrompt, !prompt.isEmpty {
            return prompt.firstNonEmptyLine ?? prompt
        }
        if let id = sessionID { return String(id.prefix(8)) }
        return "Session"
    }
}

private extension String {
    var firstNonEmptyLine: String? {
        split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

#Preview("Monitor — empty") {
    AIMonitorSection(tasks: [])
        .frame(width: 460, height: 180)
        .background(Color.black)
}

#Preview("Monitor — populated") {
    AIMonitorSection(tasks: [
        AITask(
            id: "7af3e2",
            agentKind: .claudeCode,
            sessionID: "7af3e2",
            projectDirectory: "/Users/x/projects/Brow",
            terminalAppHint: "iTerm",
            userPrompt: "fix the auth bug in middleware",
            lastToolActivity: "Editing middleware.ts",
            status: .working("Editing…"),
            lastActivityAt: Date().addingTimeInterval(-1620),
            currentApproval: nil,
            currentQuestion: nil
        ),
        AITask(
            id: "b91c4d",
            agentKind: .codex,
            sessionID: "b91c4d",
            projectDirectory: "/Users/x/projects/api-server",
            terminalAppHint: "Terminal",
            userPrompt: nil,
            lastToolActivity: "git push origin main",
            status: .working(nil),
            lastActivityAt: Date().addingTimeInterval(-3600),
            currentApproval: nil,
            currentQuestion: nil
        ),
        AITask(
            id: "c52f81",
            agentKind: .geminiCLI,
            sessionID: "c52f81",
            projectDirectory: "/Users/x/projects/docs",
            terminalAppHint: "Ghostty",
            userPrompt: nil,
            lastToolActivity: nil,
            status: .done(nil),
            lastActivityAt: Date().addingTimeInterval(-18_000),
            currentApproval: nil,
            currentQuestion: nil
        ),
    ])
    .frame(width: 460, height: 200)
    .background(Color.black)
}
