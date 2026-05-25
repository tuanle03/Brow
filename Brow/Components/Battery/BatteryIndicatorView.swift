//
//  BatteryIndicatorView.swift
//  Brow
//
//  Custom-drawn battery "pill" with an optional percentage label and a bolt
//  overlay when charging. Used inline in the closed/hovered notch as well as
//  larger inside the expanded view.
//

import SwiftUI

struct BatteryIndicatorView: View {
    let info: BatteryInfo
    var showPercentage: Bool = true
    var bodyWidth: CGFloat = 22
    var bodyHeight: CGFloat = 10

    var body: some View {
        HStack(spacing: 4) {
            if showPercentage {
                Text("\(info.percentage)%")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.78))
                    .monospacedDigit()
            }

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2.5)
                    .stroke(.white.opacity(0.45), lineWidth: 1)
                    .frame(width: bodyWidth, height: bodyHeight)

                RoundedRectangle(cornerRadius: 1.5)
                    .fill(fillColor)
                    .frame(
                        width: max(2, (bodyWidth - 2) * CGFloat(info.percentage) / 100),
                        height: bodyHeight - 3
                    )
                    .padding(.leading, 1.5)

                if info.isCharging {
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 7, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: bodyWidth, alignment: .center)
                }
            }
            .overlay(alignment: .trailing) {
                Capsule()
                    .fill(.white.opacity(0.45))
                    .frame(width: 1.5, height: bodyHeight * 0.5)
                    .offset(x: 2)
            }
        }
    }

    private var fillColor: Color {
        if info.isCharging || info.isPluggedIn { return .green }
        if info.percentage <= 20 { return .red }
        return .white.opacity(0.85)
    }
}
