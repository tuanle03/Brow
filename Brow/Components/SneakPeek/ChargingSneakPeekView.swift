//
//  ChargingSneakPeekView.swift
//  Brow
//
//  Transient overlay shown when the AC adapter is plugged in or unplugged.
//

import SwiftUI

struct ChargingSneakPeekView: View {
    let plugged: Bool
    let percentage: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: plugged ? "bolt.fill" : "battery.50percent")
                .font(.title3)
                .foregroundStyle(plugged ? .yellow : .white)
                .symbolRenderingMode(.hierarchical)

            VStack(alignment: .leading, spacing: 1) {
                Text(plugged ? "Charging" : "On Battery")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                Text("\(percentage)%")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.7))
                    .monospacedDigit()
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 6)
    }
}
