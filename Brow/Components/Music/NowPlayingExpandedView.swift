//
//  NowPlayingExpandedView.swift
//  Brow
//
//  Full now-playing surface shown when the notch is in the `.open` state.
//  Includes large artwork, track metadata, and prev/play-pause/next controls.
//

import SwiftUI

struct NowPlayingExpandedView: View {
    let track: PlaybackTrack?
    let artwork: NSImage?
    var onPrev: () -> Void
    var onPlayPause: () -> Void
    var onNext: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            artworkView
                .frame(width: 84, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(displayTitle)
                    .font(.subheadline.bold())
                    .foregroundStyle(.white)
                    .lineLimit(1)

                Text(displaySubtitle)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)

                Spacer(minLength: 0)

                HStack(spacing: 22) {
                    controlButton(systemName: "backward.fill", action: onPrev)
                    controlButton(
                        systemName: track?.isPlaying == true ? "pause.fill" : "play.fill",
                        action: onPlayPause,
                        large: true
                    )
                    controlButton(systemName: "forward.fill", action: onNext)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var displayTitle: String {
        let t = track?.title ?? ""
        return t.isEmpty ? "Not playing" : t
    }

    private var displaySubtitle: String {
        guard let track, !track.artist.isEmpty else { return "" }
        if track.album.isEmpty { return track.artist }
        return "\(track.artist) — \(track.album)"
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(0.08))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.title)
                        .foregroundStyle(.white.opacity(0.4))
                }
        }
    }

    @ViewBuilder
    private func controlButton(
        systemName: String,
        action: @escaping () -> Void,
        large: Bool = false
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(large ? .title3 : .body)
                .foregroundStyle(.white)
                .frame(width: large ? 28 : 22, height: large ? 28 : 22)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
