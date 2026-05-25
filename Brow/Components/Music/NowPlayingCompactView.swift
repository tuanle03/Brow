//
//  NowPlayingCompactView.swift
//  Brow
//
//  Tiny now-playing strip that fits inside the closed/hovered notch silhouette:
//  small artwork followed by an animated waveform when playback is active.
//  No trailing spacer — outer layouts arrange this alongside other widgets.
//

import SwiftUI

struct NowPlayingCompactView: View {
    let track: PlaybackTrack?
    let artwork: NSImage?

    var body: some View {
        HStack(spacing: 4) {
            artworkView
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 4))

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
