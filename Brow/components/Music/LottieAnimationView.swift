//
//  LottieAnimationContainer.swift
//  Brow
//
//  Created by Richard Kunkli on 2024. 10. 29..
//

import SwiftUI
import Defaults

struct LottieAnimationContainer: View {
    @Default(.selectedVisualizer) var selectedVisualizer

    var body: some View {
        if let v = selectedVisualizer {
            // One global scale, applied via SwiftUI scaleEffect. Each
            // display's notch container is sized independently, so a
            // single scale value produces a proportionally-equivalent
            // result everywhere.
            LottieView(url: v.url, speed: v.speed, loopMode: .loop)
                .scaleEffect(v.scale, anchor: .center)
                .clipped()
        } else {
            LottieView(
                url: URL(string: "https://assets9.lottiefiles.com/packages/lf20_mniampqn.json")!,
                speed: 1.0,
                loopMode: .loop
            )
        }
    }
}

#Preview {
    LottieAnimationContainer()
}
