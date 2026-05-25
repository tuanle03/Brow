//
//  NowPlayingCompactView.swift
//  Brow
//
//  Tiny now-playing strip that fits inside the closed/hovered notch silhouette:
//  small artwork on the left edge + animated waveform on the right edge.
//

import SwiftUI

struct NowPlayingCompactView: View {
    let track: PlaybackTrack?
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 6) {
            artworkView
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Spacer(minLength: 0)
            if track?.isPlaying == true {
                Image(systemName: "waveform")
                    .font(.caption2)
                    .foregroundStyle(.white)
                    .symbolEffect(.variableColor.iterative.dimInactiveLayers, isActive: true)
            }
        }
    }

    @ViewBuilder
    private var artworkView: some View {
        if let artwork {
            Image(nsImage: artwork)
                .resizable()
                .scaledToFill()
        } else {
            RoundedRectangle(cornerRadius: 4)
                .fill(.white.opacity(0.08))
                .overlay {
                    Image(systemName: "music.note")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.4))
                }
        }
    }
}
