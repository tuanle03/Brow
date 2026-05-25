//
//  BatteryDetailView.swift
//  Brow
//
//  Rich battery section shown in the expanded notch: large pill indicator
//  plus a state label (charging / plugged in / on battery / low power) and a
//  time-remaining estimate when available.
//

import SwiftUI

struct BatteryDetailView: View {
    let info: BatteryInfo

    var body: some View {
        HStack(spacing: 10) {
            BatteryIndicatorView(
                info: info,
                showPercentage: false,
                bodyWidth: 30,
                bodyHeight: 14
            )

            VStack(alignment: .leading, spacing: 1) {
                Text("\(info.percentage)% · \(stateLabel)")
                    .font(.caption.bold())
                    .foregroundStyle(.white)
                if let subtitle {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.65))
                }
            }

            Spacer(minLength: 0)
        }
    }

    private var stateLabel: String {
        if info.isCharging { return "Charging" }
        if info.isPluggedIn { return "Plugged In" }
        return "On Battery"
    }

    private var subtitle: String? {
        if info.isCharging, let m = info.timeToFull {
            return "\(formatMinutes(m)) until full"
        }
        if !info.isPluggedIn, let m = info.timeToEmpty {
            return "\(formatMinutes(m)) remaining"
        }
        if info.isLowPowerMode {
            return "Low Power Mode"
        }
        return nil
    }

    private func formatMinutes(_ minutes: Int) -> String {
        if minutes >= 60 {
            let h = minutes / 60
            let m = minutes % 60
            return m > 0 ? "\(h)h \(m)m" : "\(h)h"
        }
        return "\(minutes)m"
    }
}
