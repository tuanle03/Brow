//
//  SessionListView.swift
//  Brow
//
//  Task 2.5: the v8 expanded-notch session list — a header (title + a
//  per-status count summary) over a scrolling, grouped list of
//  `SessionRowView`s. Reads `AIAppModel.shared.islandSessionSections`
//  (Task 2.5's pure ranking/grouping/staleness logic) and just renders it;
//  no ranking/derivation lives in this file.
//
//  NOT wired into ContentView yet — that's Task 2.7's job, which also owns
//  passing a real `TerminalJumpService`-backed `onJump`.
//

import SwiftUI

struct SessionListView: View {
    var model: AIAppModel = .shared
    var group: IslandSessionGroup = .state
    var sort: IslandSessionSort = .attention
    var onJump: (AgentSession) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(sections) { section in
                        if group != .none {
                            sessionSectionHeader(section)
                        }
                        ForEach(section.sessions) { session in
                            SessionRowView(session: session, onJump: onJump)
                            if session.id != section.sessions.last?.id {
                                Divider().overlay(V6Palette.paper.opacity(0.08))
                            }
                        }
                    }
                }
            }
        }
        .background(V6Palette.ink)
    }

    private var sections: [IslandSessionSection] {
        model.islandSessionSections(group: group, sort: sort, now: Date())
    }

    private var visibleSessions: [AgentSession] {
        model.surfacedSessions(now: Date())
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Text("Sessions")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(V6Palette.paper)

            Spacer()

            statusCounts
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var statusCounts: some View {
        let sessions = visibleSessions
        let attentionCount = sessions.filter(\.phase.requiresAttention).count
        let runningCount = sessions.filter { $0.phase == .running }.count

        return HStack(spacing: 8) {
            if attentionCount > 0 {
                countBadge(attentionCount, tint: IslandStatus.waiting)
            }
            if runningCount > 0 {
                countBadge(runningCount, tint: IslandStatus.running)
            }
            Text("\(sessions.count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(V6Palette.paper.opacity(0.5))
        }
    }

    private func countBadge(_ count: Int, tint: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text("\(count)")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(V6Palette.paper.opacity(0.8))
        }
    }

    // MARK: - Section header

    private func sessionSectionHeader(_ section: IslandSessionSection) -> some View {
        Text(section.title.uppercased())
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(V6Palette.paper.opacity(0.4))
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 4)
    }
}

// MARK: - Previews

#Preview("SessionListView — grouped by state") {
    let now = Date()
    let model = AIAppModel()
    for session in SessionListView.previewSessions(now: now) {
        model.state.sessionsByID[session.id] = session
    }
    return SessionListView(model: model, group: .state, sort: .attention) { print("jump to \($0.id)") }
        .frame(width: 340, height: 480)
}

#Preview("SessionListView — ungrouped, last-update sort") {
    let now = Date()
    let model = AIAppModel()
    for session in SessionListView.previewSessions(now: now) {
        model.state.sessionsByID[session.id] = session
    }
    return SessionListView(model: model, group: .none, sort: .lastUpdate) { print("jump to \($0.id)") }
        .frame(width: 340, height: 480)
}

extension SessionListView {
    /// Hand-built demo sessions spanning every phase, for previews only.
    fileprivate static func previewSessions(now: Date) -> [AgentSession] {
        [
            AgentSession(
                id: "approval", title: "Brow · feature/open-island-parity", tool: .claudeCode,
                phase: .waitingForApproval,
                summary: "Wants to run rm -rf build/",
                updatedAt: now.addingTimeInterval(-30),
                permissionRequest: PermissionRequest(id: "p1", title: "Run command", summary: "Wants to run rm -rf build/", affectedPath: "build/"),
                jumpTarget: JumpTarget(terminalApp: "com.googlecode.iterm2", workspaceName: "Brow", paneTitle: "zsh"),
                isProcessAlive: true
            ),
            AgentSession(
                id: "answer", title: "docs-site · main", tool: .codex,
                phase: .waitingForAnswer,
                summary: "Which package manager should I use?",
                updatedAt: now.addingTimeInterval(-90),
                questionPrompt: QuestionPrompt(title: "Which package manager?", questions: []),
                jumpTarget: JumpTarget(terminalApp: "com.apple.Terminal", workspaceName: "docs-site", paneTitle: "zsh"),
                isProcessAlive: true
            ),
            AgentSession(
                id: "running", title: "vibe-island · main", tool: .codex,
                phase: .running,
                summary: "Running pytest",
                updatedAt: now.addingTimeInterval(-120),
                jumpTarget: JumpTarget(terminalApp: "com.apple.Terminal", workspaceName: "vibe-island", paneTitle: "zsh"),
                isProcessAlive: true
            ),
            AgentSession(
                id: "done", title: "dotfiles · chore/cleanup", tool: .claudeCode,
                phase: .completed,
                summary: "Finished refactor",
                updatedAt: now.addingTimeInterval(-60)
            ),
            AgentSession(
                id: "idle", title: "notes · main", tool: .claudeCode,
                phase: .completed,
                summary: "Wrote weekly notes",
                updatedAt: now.addingTimeInterval(-3_600)
            ),
        ]
    }
}
