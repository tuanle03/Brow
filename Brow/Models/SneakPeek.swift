//
//  SneakPeek.swift
//  Brow
//
//  Transient overlays shown above the resting notch UI: e.g. plugging the
//  charger in, volume change, brightness change. Each peek auto-dismisses
//  after `duration` seconds. Phase 2 only emits `.charging`; other kinds
//  land in Phase 4 (HUD replacement).
//

import Foundation

enum SneakPeekKind: Equatable, Sendable {
    case charging(plugged: Bool, percentage: Int)
}

struct SneakPeek: Equatable, Sendable {
    let kind: SneakPeekKind
    let duration: TimeInterval
}
