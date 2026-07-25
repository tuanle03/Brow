//
//  V8ClosedPill.swift
//  Brow
//
//  Task 2.4: renders whichever content `AIAppModel.closedPillContent(...)`
//  resolved as the winner, inside Brow's own closed-notch pill shape
//  (`NotchShape` + `cornerRadiusInsets.closed`, filled `V6Palette.ink`).
//  Purely a rendering layer — precedence lives in
//  `AIAppModel.closedPillContent`, this view only switches on the
//  already-resolved `ClosedPillContent`.
//
//  NOT wired into `ContentView` yet (Task 2.7 mounts it into the real
//  closed-notch strip and passes the live `vm.closedNotchSize`) — the
//  `size` default here is a preview stand-in only.
//

import SwiftUI

struct V8ClosedPill: View {
    var content: ClosedPillContent

    /// Only read for `.aiAttention` — the winning session, looked up by the
    /// caller from `AIAppModel.state.sessionsByID[sessionID]`. Kept as a
    /// parameter (not an `AIAppModel` dependency) so this view stays a pure
    /// renderer, easy to preview/test in isolation.
    var attentionSession: AgentSession?
    /// How many visible sessions currently need attention. Shown as a small
    /// trailing count when > 1 — mirrors `BrowMascot`'s own badge rule.
    var attentionCount: Int = 1

    var size: CGSize = CGSize(width: 150, height: 32)

    var body: some View {
        ZStack {
            NotchShape(
                topCornerRadius: cornerRadiusInsets.closed.top,
                bottomCornerRadius: cornerRadiusInsets.closed.bottom
            )
            .fill(V6Palette.ink)

            inner
                .padding(.horizontal, 10)
        }
        .frame(width: size.width, height: size.height)
    }

    @ViewBuilder
    private var inner: some View {
        switch content {
        case .aiAttention:
            HStack(spacing: 6) {
                UnifiedBarsGlyph(
                    mode: .waiting,
                    tint: IslandStatus.tint(for: attentionSession?.phase ?? .waitingForApproval)
                )
                .frame(width: 24, height: 24)

                if attentionCount > 1 {
                    Text("\(attentionCount)")
                        .font(.system(size: 11, weight: .bold, design: .monospaced))
                        .foregroundStyle(V6Palette.paper.opacity(0.85))
                }
            }

        case .aiRunning:
            UnifiedBarsGlyph(mode: .running)
                .frame(width: 24, height: 24)

        case .music:
            V8ClosedPillMusic()

        case .mascot:
            BrowMascot(state: .idle, size: 20)

        case .empty:
            EmptyView()
        }
    }
}

/// `.music` case — a restyle of Brow's existing closed-notch music layout
/// onto the v8 ink palette: album art on the left, a marquee title on the
/// right, same as `ContentView.MusicLiveActivity`. That original is a
/// private `@ViewBuilder` method on `ContentView` (bound to its own
/// `albumArtNamespace` / `coordinator` / `vm`), not an extractable `View`
/// type — and this task's scope explicitly excludes touching `ContentView`.
/// So rather than duplicating `ContentView`, this reads the same
/// `MusicManager.shared` source of truth and reuses the same `MarqueeText`
/// component the original wraps, preserving the album-art + marquee
/// behavior the brief asks to keep. The sneak-peek/expanding-view artist
/// line and `matchedGeometryEffect` (namespace-bound, `ContentView`-only)
/// aren't reproduced — they're `ContentView` layout details, not this
/// slot's content.
private struct V8ClosedPillMusic: View {
    @ObservedObject private var musicManager = MusicManager.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(nsImage: musicManager.albumArt)
                .resizable()
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
                .frame(width: 20, height: 20)

            MarqueeText(
                .constant(musicManager.songTitle),
                font: .caption,
                textColor: V6Palette.paper,
                minDuration: 0.4,
                frameWidth: 90
            )
        }
    }
}

// MARK: - Previews

#Preview("V8ClosedPill — aiAttention") {
    V8ClosedPill(
        content: .aiAttention(sessionID: "s1"),
        attentionSession: AgentSession(id: "s1", tool: .claudeCode, phase: .waitingForApproval),
        attentionCount: 2,
        size: getClosedNotchSize()
    )
    .padding(24)
    .background(Color.black)
}

#Preview("V8ClosedPill — aiRunning") {
    V8ClosedPill(content: .aiRunning, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}

#Preview("V8ClosedPill — music") {
    V8ClosedPill(content: .music, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}

#Preview("V8ClosedPill — mascot") {
    V8ClosedPill(content: .mascot, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}

#Preview("V8ClosedPill — empty") {
    V8ClosedPill(content: .empty, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}
