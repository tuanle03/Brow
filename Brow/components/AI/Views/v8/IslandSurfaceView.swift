//
//  IslandSurfaceView.swift
//  Brow
//
//  Task 2.6: the top-level v8 notch renderer — switches on the current
//  `IslandSurface` and renders the matching content (`SessionListView` or
//  one of the three notification cards), looking the actionable
//  `AgentSession` up from `AIAppModel.state.sessionsByID` by the surface's
//  `actionableSessionID`. `.closed` renders nothing here — the closed pill
//  is `V8ClosedPill` (Task 2.4), mounted separately.
//
//  Reuses Brow's `NotchShape` (opened corner radii) as the container so the
//  shell shape matches the rest of the notch UI; surface transitions
//  animate with the reference's open/close springs — a snappy spring when
//  opening into a card/list, a smooth ease when collapsing back to
//  `.closed`.
//
//  NOT wired into `ContentView` yet (Task 2.7's job) — this is a
//  standalone, previewable component, driven here by a plain `surface`
//  property rather than reading `ContentViewModel`.
//

import SwiftUI

struct IslandSurfaceView: View {
    var surface: IslandSurface
    var model: AIAppModel = .shared
    var onJump: (AgentSession) -> Void = { _ in }

    var body: some View {
        Group {
            switch surface {
            case .closed:
                EmptyView()
            case .sessionList:
                shell { SessionListView(model: model, onJump: onJump) }
            case let .approvalCard(sessionID):
                cardShell(for: sessionID) { session in ApprovalCardView(session: session, model: model) }
            case let .questionCard(sessionID):
                cardShell(for: sessionID) { session in QuestionCardView(session: session, model: model) }
            case let .completionCard(sessionID):
                cardShell(for: sessionID) { session in CompletionCardView(session: session, model: model) }
            }
        }
        .animation(surfaceAnimation, value: surface)
    }

    /// Ported from the reference's open/close timing: a snappy spring when
    /// a card/list opens, a smoother ease when collapsing to `.closed`.
    private var surfaceAnimation: Animation {
        surface == .closed ? .smooth(duration: 0.3) : .spring(response: 0.42, dampingFraction: 0.8)
    }

    @ViewBuilder
    private func cardShell<Content: View>(
        for sessionID: String,
        @ViewBuilder content: (AgentSession) -> Content
    ) -> some View {
        if let session = model.state.sessionsByID[sessionID] {
            shell { content(session) }
        } else {
            // The session vanished (e.g. resolved/ended) between the
            // surface being set and this render — nothing to show.
            EmptyView()
        }
    }

    @ViewBuilder
    private func shell<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .background(
                NotchShape(
                    topCornerRadius: cornerRadiusInsets.opened.top,
                    bottomCornerRadius: cornerRadiusInsets.opened.bottom
                )
                .fill(V6Palette.ink)
            )
            .clipShape(
                NotchShape(
                    topCornerRadius: cornerRadiusInsets.opened.top,
                    bottomCornerRadius: cornerRadiusInsets.opened.bottom
                )
            )
    }
}

// MARK: - Previews

#Preview("IslandSurfaceView — session list") {
    let model = AIAppModel()
    model.state.sessionsByID["s1"] = AgentSession(
        id: "s1", title: "Brow · main", tool: .claudeCode, phase: .running, summary: "Running tests"
    )
    return IslandSurfaceView(surface: .sessionList, model: model)
        .frame(width: 340, height: 420)
        .padding(24)
        .background(Color.black)
}

#Preview("IslandSurfaceView — approval card") {
    let model = AIAppModel()
    model.state.sessionsByID["s1"] = AgentSession(
        id: "s1", title: "Brow · main", tool: .claudeCode,
        phase: .waitingForApproval,
        summary: "Wants to run rm -rf build/",
        permissionRequest: PermissionRequest(
            id: "p1", title: "Run command", summary: "rm -rf build/", affectedPath: "build/", toolName: "Bash"
        )
    )
    return IslandSurfaceView(surface: .approvalCard(sessionID: "s1"), model: model)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .background(Color.black)
}

#Preview("IslandSurfaceView — question card") {
    let model = AIAppModel()
    model.state.sessionsByID["s1"] = AgentSession(
        id: "s1", title: "Brow · main", tool: .claudeCode,
        phase: .waitingForAnswer,
        summary: "Which package manager?",
        questionPrompt: QuestionPrompt(
            title: "Which package manager?",
            questions: [
                QuestionPromptItem(
                    question: "Which package manager should I use?",
                    header: "Answer needed",
                    options: [QuestionOption(label: "npm"), QuestionOption(label: "pnpm")]
                ),
            ]
        )
    )
    return IslandSurfaceView(surface: .questionCard(sessionID: "s1"), model: model)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .background(Color.black)
}

#Preview("IslandSurfaceView — completion card") {
    let model = AIAppModel()
    model.state.sessionsByID["s1"] = AgentSession(
        id: "s1", title: "Brow · main", tool: .claudeCode,
        phase: .completed,
        summary: "Finished the refactor and pushed the branch."
    )
    return IslandSurfaceView(surface: .completionCard(sessionID: "s1"), model: model)
        .frame(width: 340)
        .fixedSize(horizontal: false, vertical: true)
        .padding(24)
        .background(Color.black)
}

#Preview("IslandSurfaceView — closed (renders nothing)") {
    IslandSurfaceView(surface: .closed, model: AIAppModel())
        .frame(width: 340, height: 40)
        .padding(24)
        .background(Color.black)
}
