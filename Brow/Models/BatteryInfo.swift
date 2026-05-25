//
//  BatteryInfo.swift
//  Brow
//

import Foundation

struct BatteryInfo: Equatable, Sendable {
    var percentage: Int          // 0-100
    var isCharging: Bool
    var isPluggedIn: Bool        // AC connected (charging or fully charged)
    var timeToFull: Int?         // minutes; nil if unknown / not charging
    var timeToEmpty: Int?        // minutes; nil if unknown / plugged in
    var isLowPowerMode: Bool
}

extension BatteryInfo {
    static let placeholder = BatteryInfo(
        percentage: 100,
        isCharging: false,
        isPluggedIn: false,
        timeToFull: nil,
        timeToEmpty: nil,
        isLowPowerMode: false
    )
}
