//
//  IdleLottieActivity.swift
//  Brow
//
//  Closed-notch live activity shown when no music is playing. Mirrors the
//  layout of `MusicLiveActivity` so the Lottie sits on the right where users
//  already expect it; the album-art slot is intentionally left empty.
//
//  Reads `selectedIdleVisualizer` rather than `selectedVisualizer` so the
//  user can pick a *different* Lottie for the idle state than for music.
//

import SwiftUI
import Defaults

struct IdleLottieActivity: View {
    @EnvironmentObject var vm: BrowViewModel
    @Default(.selectedIdleVisualizer) private var selectedIdleVisualizer

    var body: some View {
        HStack {
            // Empty left slot — mirrors the album-art slot in `MusicLiveActivity`.
            Rectangle()
                .fill(.clear)
                .frame(
                    width: max(0, vm.effectiveClosedNotchHeight - 12),
                    height: max(0, vm.effectiveClosedNotchHeight - 12)
                )

            // Central strip covering the camera/menubar area.
            Rectangle()
                .fill(.black)
                .frame(width: vm.closedNotchSize.width - 20)

            // Right slot: user's idle Lottie.
            HStack {
                if let v = selectedIdleVisualizer {
                    LottieView(url: v.url, speed: v.speed, loopMode: .loop)
                        .scaleEffect(v.scale, anchor: .center)
                        .clipped()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(
                width: max(0, vm.effectiveClosedNotchHeight - 12),
                height: max(0, vm.effectiveClosedNotchHeight - 12)
            )
        }
        .frame(height: vm.effectiveClosedNotchHeight, alignment: .center)
    }
}
