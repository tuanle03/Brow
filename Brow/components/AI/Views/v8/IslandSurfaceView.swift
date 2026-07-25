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
//  Surface transitions animate with the reference's open/close springs — a
//  snappy spring when opening into a card/list, a smooth ease when
//  collapsing back to `.closed`.
//
//  Draws no background/shape of its own — mirrors the pre-v8 `AIPanel`
//  (see `git show 78cbf6f~1:Brow/components/AI/Views/AIPanel.swift`), which
//  filled the space it was given and let the surrounding `NotchLayout`
//  container own the shape and fill. `ContentView`'s outer
//  `.background(V6Palette.ink).clipShape(currentNotchShape)` is that single
//  fill+shape for the whole island; a second nested `NotchShape` fill here,
//  sized only to this view's own intrinsic content, drifts out of sync with
//  the outer one and shows up as a mismatched inset panel with clipped
//  content.
//

import SwiftUI

/// Measures its content's natural height so `AutoHeightScrollView` can pin
/// its frame to `min(measured, cap)`.
private struct IslandContentHeightKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Auto-height container ported from Open Island's `AutoHeightScrollView`.
/// Content is *always* wrapped in a ScrollView so it gets unconstrained
/// vertical space to report its natural height (a tight parent window would
/// otherwise cap the measurement and make long content look truncated
/// instead of scrollable). The frame is then pinned to `min(measured, cap)`,
/// so the panel hugs short content and the ScrollView only actually scrolls
/// once content exceeds the cap. A 2pt tolerance breaks the
/// measure → resize → measure feedback loop.
struct AutoHeightScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: () -> Content
    @State private var contentHeight: CGFloat = 0

    private var isScrollable: Bool { contentHeight > maxHeight }

    var body: some View {
        ScrollView(.vertical) {
            content()
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: IslandContentHeightKey.self, value: geo.size.height)
                    }
                )
                .onPreferenceChange(IslandContentHeightKey.self) { height in
                    if height > 0, abs(height - contentHeight) > 2 { contentHeight = height }
                }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollIndicators(isScrollable ? .automatic : .hidden)
        .frame(height: openIslandContentHeight(measured: contentHeight, cap: maxHeight))
    }
}

struct IslandSurfaceView: View {
    var surface: IslandSurface
    var model: AIAppModel = .shared
    var onJump: (AgentSession) -> Void = { _ in }
    /// Cap the panel content grows to before it scrolls. Defaults to the
    /// full window cap; `ContentView` passes the header-adjusted value.
    var maxContentHeight: CGFloat = maxOpenNotchHeight

    var body: some View {
        AutoHeightScrollView(maxHeight: maxContentHeight) {
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
            // Breathing room below the notch/header so the first line of
            // content doesn't sit flush at the panel's top edge.
            .padding(.top, 6)
            .animation(surfaceAnimation, value: surface)
        }
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
        // Fill width but size to intrinsic HEIGHT — `AutoHeightScrollView`
        // measures that natural height to drive the auto-height + cap + scroll
        // model. A `maxHeight: .infinity` here would collapse the measurement
        // (content would always report the container height, never its own),
        // reintroducing the fixed-height clipping this replaced.
        content()
            .frame(maxWidth: .infinity, alignment: .top)
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
