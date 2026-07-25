//
//  V8ClosedPill.swift
//  Brow
//
//  Task 2.4: renders whichever content `AIAppModel.closedPillContent(...)`
//  resolved as the winner. Purely a rendering layer — precedence lives in
//  `AIAppModel.closedPillContent`, this view only switches on the
//  already-resolved `ClosedPillContent`.
//
//  Draws no background/shape of its own — `ContentView`'s outer
//  `.background(V6Palette.ink).clipShape(currentNotchShape)` is the single
//  fill+shape for the whole island (closed pill and open panel alike). A
//  second nested `NotchShape` fill here would drift out of sync with the
//  outer one (different padding) and show up as a black band around this
//  pill instead of one seamless shape.
//
//  NOT wired into `ContentView` yet (Task 2.7 mounts it into the real
//  closed-notch strip and passes the live `vm.closedNotchSize`) — the
//  `size` default here is a preview stand-in only.
//

import Defaults
import SwiftUI

struct V8ClosedPill: View {
    var content: ClosedPillContent

    /// `ContentView`'s `@Namespace var albumArtNamespace` — threaded down so
    /// the `.music` case's album art can `matchedGeometryEffect` into
    /// `NotchHomeView`'s open player (`AlbumArtView`'s `albumArtImage` uses
    /// the same id/namespace). Without this the closed→open morph only ran
    /// one-sided and popped instead of animating.
    var albumArtNamespace: Namespace.ID

    /// Only read for `.aiAttention` — the winning session, looked up by the
    /// caller from `AIAppModel.state.sessionsByID[sessionID]`. Kept as a
    /// parameter (not an `AIAppModel` dependency) so this view stays a pure
    /// renderer, easy to preview/test in isolation.
    var attentionSession: AgentSession?
    /// How many visible sessions currently need attention. Shown as a small
    /// trailing count when > 1 — mirrors `BrowMascot`'s own badge rule.
    var attentionCount: Int = 1

    /// Task 2.7: state for the `.mascot` case's `BrowMascot`. By the time
    /// `.mascot` wins the precedence resolver there's no attention/running
    /// session left to derive `.attention`/`.working` from (those outrank
    /// `.mascot`) — the only thing left to show is a brief `.approved`/
    /// `.denied` flash right after the caller resolves a decision, else
    /// `.idle`. Caller (`ContentView`) computes and passes this; kept as a
    /// parameter so this view stays a pure renderer.
    var mascotState: BrowMascot.MascotState = .idle

    var size: CGSize = CGSize(width: 150, height: 32)

    /// Physical-notch cutout width for THIS screen, or `0` on a display with
    /// no notch. Non-zero switches the pill to the MacBook split layout:
    /// content in the two lanes flanking the cutout, nothing in the center
    /// span where the camera housing would hide it. Resolved per-screen by
    /// `ContentView` (`screenHasNotch(vm.screenUUID)`), so each window adapts
    /// to its own display automatically.
    var notchWidth: CGFloat = 0

    private var isNotched: Bool { notchWidth > 0 }

    /// Per-side lane width in the notched layout. Music needs room for album
    /// art + a short marquee; the glyph/mascot cases only need the 24pt glyph
    /// (reference `V6ClosedPill.macbookBody` reserves 44). Left and right
    /// lanes are always equal so the reserved center gap stays centered on
    /// the cutout.
    private var laneWidth: CGFloat { content == .music ? 74 : 44 }

    var body: some View {
        if isNotched {
            macbookInner
                .frame(width: notchedClosedPillWidth(notchWidth: notchWidth, laneWidth: laneWidth),
                       height: size.height)
        } else {
            inner
                .padding(.horizontal, 10)
                .frame(width: size.width, height: size.height)
        }
    }

    /// MacBook split: left lane · reserved notch span · right lane. The
    /// center `Spacer` is exactly the cutout width so no content ever lands
    /// under the physical notch.
    @ViewBuilder
    private var macbookInner: some View {
        if content == .music {
            // Music owns its own MusicManager, so it does the split
            // internally (album+marquee left, spectrum right) — same equal
            // lanes, keyed off the same `laneWidth`.
            V8ClosedPillMusic(albumArtNamespace: albumArtNamespace, notchWidth: notchWidth, laneWidth: laneWidth)
        } else {
            HStack(spacing: 0) {
                laneLeft.frame(width: laneWidth, alignment: .leading)
                Spacer().frame(width: notchWidth)
                laneRight.frame(width: laneWidth, alignment: .trailing)
            }
        }
    }

    /// Left lane content for the non-music notched cases (the glyph/mascot).
    @ViewBuilder
    private var laneLeft: some View {
        switch content {
        case .aiAttention:
            UnifiedBarsGlyph(
                mode: .waiting,
                tint: IslandStatus.tint(for: attentionSession?.phase ?? .waitingForApproval)
            )
            .frame(width: 24, height: 24)
        case .aiRunning:
            UnifiedBarsGlyph(mode: .running).frame(width: 24, height: 24)
        case .mascot:
            BrowMascot(state: mascotState, size: 20)
        case .music, .empty:
            EmptyView()
        }
    }

    /// Right lane content: only `.aiAttention` has a trailing slot (the
    /// multi-session count); the others leave the right lane empty (it still
    /// reserves width, keeping the cutout gap centered).
    @ViewBuilder
    private var laneRight: some View {
        if case .aiAttention = content, attentionCount > 1 {
            Text("\(attentionCount)")
                .font(.system(size: 11, weight: .bold, design: .monospaced))
                .foregroundStyle(V6Palette.paper.opacity(0.85))
        } else {
            EmptyView()
        }
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
            V8ClosedPillMusic(albumArtNamespace: albumArtNamespace)

        case .mascot:
            BrowMascot(state: mascotState, size: 20)

        case .empty:
            EmptyView()
        }
    }
}

/// `.music` case — a restyle of Brow's existing closed-notch music layout
/// (the deleted `ContentView.MusicLiveActivity`, see `git show
/// 78cbf6f~1:Brow/ContentView.swift`) onto the v8 ink palette: album art
/// (morphing into `NotchHomeView`'s open player via `albumArtNamespace`) on
/// the left, title + artist in the middle, spectrum visualizer (or Lottie
/// idle animation) on the right.
private struct V8ClosedPillMusic: View {
    @ObservedObject private var musicManager = MusicManager.shared
    @Default(.useMusicVisualizer) private var useMusicVisualizer
    @Default(.coloredSpectrogram) private var coloredSpectrogram

    let albumArtNamespace: Namespace.ID

    /// Non-zero → notched display: reserve this center span for the physical
    /// notch (album+title in the left lane, spectrum in the right), instead of
    /// spanning content across the cutout.
    var notchWidth: CGFloat = 0
    /// Per-side lane width in the notched layout (set by the parent so the
    /// pill's outer frame and this content agree on width — no slack, so the
    /// reserved gap stays centered on the cutout).
    var laneWidth: CGFloat = 0

    var body: some View {
        if notchWidth > 0 {
            HStack(spacing: 0) {
                HStack(spacing: 8) {
                    albumArt
                    MarqueeText(
                        .constant(musicManager.songTitle),
                        font: .caption,
                        textColor: V6Palette.paper,
                        minDuration: 0.4,
                        frameWidth: max(0, laneWidth - 28)
                    )
                }
                .frame(width: laneWidth, alignment: .leading)

                Spacer().frame(width: notchWidth)

                spectrum.frame(width: laneWidth, alignment: .trailing)
            }
        } else {
            HStack(spacing: 8) {
                albumArt

                VStack(alignment: .leading, spacing: 1) {
                    MarqueeText(
                        .constant(musicManager.songTitle),
                        font: .caption,
                        textColor: V6Palette.paper,
                        minDuration: 0.4,
                        frameWidth: 72
                    )
                    Text(musicManager.artistName)
                        .font(.system(size: 9))
                        .foregroundStyle(V6Palette.paper.opacity(0.6))
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                spectrum
            }
        }
    }

    private var albumArt: some View {
        Image(nsImage: musicManager.albumArt)
            .resizable()
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: MusicPlayerImageSizes.cornerRadiusInset.closed))
            .matchedGeometryEffect(id: "albumArt", in: albumArtNamespace)
            .frame(width: 20, height: 20)
    }

    @ViewBuilder
    private var spectrum: some View {
        if useMusicVisualizer {
            Rectangle()
                .fill(
                    coloredSpectrogram
                        ? Color(nsColor: musicManager.avgColor).gradient
                        : Color.gray.gradient
                )
                .frame(width: 16, height: 12)
                .mask {
                    AudioSpectrumView(isPlaying: $musicManager.isPlaying)
                        .frame(width: 16, height: 12)
                }
        } else {
            LottieAnimationContainer()
                .frame(width: 16, height: 12)
        }
    }
}

// MARK: - Previews

#Preview("V8ClosedPill — aiAttention") {
    V8ClosedPill(
        content: .aiAttention(sessionID: "s1"),
        albumArtNamespace: Namespace().wrappedValue,
        attentionSession: AgentSession(id: "s1", tool: .claudeCode, phase: .waitingForApproval),
        attentionCount: 2,
        size: getClosedNotchSize()
    )
    .padding(24)
    .background(Color.black)
}

#Preview("V8ClosedPill — aiRunning") {
    V8ClosedPill(content: .aiRunning, albumArtNamespace: Namespace().wrappedValue, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}

#Preview("V8ClosedPill — music") {
    V8ClosedPill(content: .music, albumArtNamespace: Namespace().wrappedValue, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}

#Preview("V8ClosedPill — mascot") {
    V8ClosedPill(content: .mascot, albumArtNamespace: Namespace().wrappedValue, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}

#Preview("V8ClosedPill — empty") {
    V8ClosedPill(content: .empty, albumArtNamespace: Namespace().wrappedValue, size: getClosedNotchSize())
        .padding(24)
        .background(Color.black)
}
