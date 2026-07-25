//
//  SessionRowView.swift
//  Brow
//
//  Task 2.5: one row in the v8 session list — a phase-tinted state dot,
//  the headline (`AgentSession.spotlightHeadline`: workspace · prompt),
//  a one-line status/summary, and a trailing agent chip + relative age +
//  detail chevron. Built directly against Brow's own v8 palette
//  (`V6Palette`, `IslandStatus.tint(for:)`, `AgentTool.brandColor`) — the
//  reference's `IslandSessionRow` (`IslandPanelView.swift`) isn't present
//  in this repo's vendored reference checkout, so this is a from-scratch
//  layout following the brief's row spec rather than a line-for-line port.
//
//  "Jump-first, spatial-split" tap semantics: tapping the row body invokes
//  `onJump` — the caller wires this to `TerminalJumpService` in Task 2.7;
//  here it defaults to a no-op so previews/tests don't need a real jump
//  target. Tapping the chevron only toggles this row's own detail
//  disclosure and never jumps.
//
//  NOT wired into ContentView (Task 2.7's job) — this is a standalone,
//  previewable component.
//

import SwiftUI

struct SessionRowView: View {
    var session: AgentSession
    var onJump: (AgentSession) -> Void = { _ in }

    @State private var isExpanded = false

    private var tint: Color { IslandStatus.tint(for: session.phase) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Circle()
                    .fill(tint)
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.spotlightHeadline)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(V6Palette.paper)
                        .lineLimit(1)
                        .truncationMode(.tail)

                    Text(session.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(V6Palette.paper.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                agentChip
                ageLabel
                chevronButton
            }
            .contentShape(Rectangle())
            .onTapGesture { onJump(session) }

            if isExpanded {
                detail
                    .padding(.leading, 18)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
        .background(V6Palette.ink)
    }

    private var agentChip: some View {
        Text(session.tool.shortName)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(session.tool.brandColor)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(session.tool.brandColor.opacity(0.16), in: Capsule())
    }

    private var ageLabel: some View {
        Text(session.updatedAt, style: .relative)
            .font(.system(size: 10, design: .monospaced))
            .foregroundStyle(V6Palette.paper.opacity(0.5))
            .fixedSize()
    }

    private var chevronButton: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(V6Palette.paper.opacity(0.5))
                .rotationEffect(.degrees(isExpanded ? 90 : 0))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var detail: some View {
        Text(detailText)
            .font(.system(size: 11))
            .foregroundStyle(V6Palette.paper.opacity(0.7))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var detailText: String {
        if let request = session.permissionRequest {
            return request.summary
        }
        if let prompt = session.questionPrompt {
            return prompt.title
        }
        return session.summary
    }
}

// MARK: - Previews

#Preview("SessionRowView — states") {
    let now = Date()
    return VStack(spacing: 1) {
        SessionRowView(session: AgentSession(
            id: "1", title: "Brow · feature/open-island-parity", tool: .claudeCode,
            phase: .waitingForApproval,
            summary: "Wants to run rm -rf build/",
            updatedAt: now.addingTimeInterval(-30),
            permissionRequest: PermissionRequest(id: "p1", title: "Run command", summary: "Wants to run rm -rf build/", affectedPath: "build/"),
            jumpTarget: JumpTarget(terminalApp: "com.googlecode.iterm2", workspaceName: "Brow", paneTitle: "zsh")
        )) { print("jump to \($0.id)") }

        SessionRowView(session: AgentSession(
            id: "2", title: "vibe-island · main", tool: .codex,
            phase: .running,
            summary: "Running pytest",
            updatedAt: now.addingTimeInterval(-120),
            jumpTarget: JumpTarget(terminalApp: "com.apple.Terminal", workspaceName: "vibe-island", paneTitle: "zsh")
        )) { print("jump to \($0.id)") }

        SessionRowView(session: AgentSession(
            id: "3", title: "dotfiles · chore/cleanup", tool: .claudeCode,
            phase: .completed,
            summary: "Finished refactor",
            updatedAt: now.addingTimeInterval(-1_800)
        )) { print("jump to \($0.id)") }
    }
    .background(V6Palette.ink)
    .frame(width: 320)
}
