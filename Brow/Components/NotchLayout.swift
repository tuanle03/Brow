//
//  NotchLayout.swift
//  Brow
//

import SwiftUI

struct NotchLayout: View {
    let coordinator: BrowViewCoordinator
    private let music = MusicManager.shared

    private var size: CGSize {
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
    }

    @ViewBuilder
    private var content: some View {
        switch coordinator.currentState {
        case .closed, .hovered:
            if music.currentTrack?.hasContent == true {
                NowPlayingCompactView(track: music.currentTrack, artwork: music.artworkImage)
            } else {
                EmptyView()
            }
        case .open:
            NowPlayingExpandedView(
                track: music.currentTrack,
                artwork: music.artworkImage,
                onPrev: { Task { await music.previous() } },
                onPlayPause: { Task { await music.togglePlayPause() } },
                onNext: { Task { await music.next() } }
            )
        }
    }
}
