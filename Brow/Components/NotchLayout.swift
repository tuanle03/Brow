//
//  NotchLayout.swift
//  Brow
//

import SwiftUI

struct NotchLayout: View {
    let coordinator: BrowViewCoordinator
    private let music = MusicManager.shared
    private let battery = BatteryActivityManager.shared

    /// When a sneak peek is showing we use the "hovered" silhouette size so
    /// there's room for the overlay content, regardless of hover state.
    private var size: CGSize {
        if coordinator.sneakPeek != nil {
            return CGSize(width: 260, height: 44)
        }
        switch coordinator.currentState {
        case .closed:
            return CGSize(width: NotchSize.closed.width, height: NotchSize.closed.height)
        case .hovered:
            return CGSize(width: NotchSize.hovered.width, height: NotchSize.hovered.height)
        case .open:
            return CGSize(width: NotchSize.open.width, height: NotchSize.open.height)
        }
    }

    var body: some View {
        ZStack(alignment: .top) {
            NotchShape(bottomCornerRadius: coordinator.currentState == .open ? 18 : 10)
                .fill(.black)

            content
                .padding(.horizontal, coordinator.currentState == .open ? 16 : 8)
                .padding(.vertical, coordinator.currentState == .open ? 12 : 4)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .frame(width: size.width, height: size.height)
        .animation(.spring(response: 0.45, dampingFraction: 0.78), value: coordinator.currentState)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: coordinator.sneakPeek)
    }

    @ViewBuilder
    private var content: some View {
        if let peek = coordinator.sneakPeek {
            sneakPeekView(for: peek)
        } else {
            switch coordinator.currentState {
            case .closed, .hovered:
                compactContent
            case .open:
                expandedContent
            }
        }
    }

    private var compactContent: some View {
        HStack(spacing: 6) {
            if music.currentTrack?.hasContent == true {
                NowPlayingCompactView(track: music.currentTrack, artwork: music.artworkImage)
            }
            Spacer(minLength: 0)
            BatteryIndicatorView(info: battery.info)
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            NowPlayingExpandedView(
                track: music.currentTrack,
                artwork: music.artworkImage,
                onPrev: { Task { await music.previous() } },
                onPlayPause: { Task { await music.togglePlayPause() } },
                onNext: { Task { await music.next() } }
            )
            BatteryDetailView(info: battery.info)
        }
    }

    @ViewBuilder
    private func sneakPeekView(for peek: SneakPeek) -> some View {
        switch peek.kind {
        case .charging(let plugged, let percentage):
            ChargingSneakPeekView(plugged: plugged, percentage: percentage)
        }
    }
}
