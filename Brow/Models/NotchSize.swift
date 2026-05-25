//
//  NotchSize.swift
//  Brow
//

import CoreGraphics

struct NotchSize: Equatable {
    var width: CGFloat
    var height: CGFloat

    static let closed = NotchSize(width: 200, height: 32)
    static let hovered = NotchSize(width: 220, height: 36)
    static let open = NotchSize(width: 620, height: 240)
}
