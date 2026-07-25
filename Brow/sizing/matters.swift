//
//  sizeMatters.swift
//  Brow
//
//  Created by Harsh Vardhan  Goswami  on 05/08/24.
//

import Defaults
import Foundation
import SwiftUI

let downloadSneakSize: CGSize = .init(width: 65, height: 1)
let batterySneakSize: CGSize = .init(width: 160, height: 1)

let shadowPadding: CGFloat = 20
let openNotchSize: CGSize = .init(width: 640, height: 240)
/// Max height the opened AI panel can grow to before its content scrolls.
/// The per-screen window is created at this height (+ shadow) and never
/// resized; the visible panel grows with its content up to this cap and
/// scrolls beyond it (Open Island's auto-height model). `openNotchSize.height`
/// stays the fixed height for the non-AI tabs (home / shelf).
let maxOpenNotchHeight: CGFloat = 560
let windowSize: CGSize = .init(width: openNotchSize.width, height: maxOpenNotchHeight + shadowPadding)

/// Opened-panel content height: grows with the measured content, capped so
/// the panel never exceeds the window. A non-positive `measured` (content not
/// yet laid out) returns `nil` so the view falls back to its intrinsic size
/// on the first layout pass. Pure so it can be unit-tested without a view.
func openIslandContentHeight(measured: CGFloat, cap: CGFloat) -> CGFloat? {
    guard measured > 0 else { return nil }
    return min(measured, cap)
}
let cornerRadiusInsets: (opened: (top: CGFloat, bottom: CGFloat), closed: (top: CGFloat, bottom: CGFloat)) = (opened: (top: 19, bottom: 24), closed: (top: 6, bottom: 14))

enum MusicPlayerImageSizes {
    static let cornerRadiusInset: (opened: CGFloat, closed: CGFloat) = (opened: 13.0, closed: 4.0)
    static let size = (opened: CGSize(width: 90, height: 90), closed: CGSize(width: 20, height: 20))
}

@MainActor func getScreenFrame(_ screenUUID: String? = nil) -> CGRect? {
    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }
    
    if let screen = selectedScreen {
        return screen.frame
    }
    
    return nil
}

/// Whether *this* screen has a physical notch (camera cutout). Same
/// detection `getClosedNotchSize` uses (`safeAreaInsets.top > 0`), pulled out
/// so the closed pill can flank the cutout on notched displays and span
/// freely on external ones. Per-screen: resolve the window's own `screenUUID`.
@MainActor func screenHasNotch(screenUUID: String? = nil) -> Bool {
    let screen = screenUUID.flatMap { NSScreen.screen(withUUID: $0) } ?? NSScreen.main
    return (screen?.safeAreaInsets.top ?? 0) > 0
}

/// Total closed-pill width on a notched display: two equal content lanes
/// flanking the reserved physical-notch span, so the empty center gap stays
/// centered on the cutout (the pill is centered on screen, so equal lanes
/// keep the gap aligned with the camera housing). `notchWidth <= 0` means the
/// display has no notch — callers use the spanning layout instead. Pure so it
/// can be unit-tested without a screen.
func notchedClosedPillWidth(notchWidth: CGFloat, laneWidth: CGFloat) -> CGFloat {
    laneWidth * 2 + max(0, notchWidth)
}

@MainActor func getClosedNotchSize(screenUUID: String? = nil) -> CGSize {
    // Default notch size, to avoid using optionals
    var notchHeight: CGFloat = Defaults[.nonNotchHeight]
    var notchWidth: CGFloat = 185

    var selectedScreen = NSScreen.main

    if let uuid = screenUUID {
        selectedScreen = NSScreen.screen(withUUID: uuid)
    }

    // Check if the screen is available
    if let screen = selectedScreen {
        // Calculate and set the exact width of the notch
        if let topLeftNotchpadding: CGFloat = screen.auxiliaryTopLeftArea?.width,
           let topRightNotchpadding: CGFloat = screen.auxiliaryTopRightArea?.width
        {
            notchWidth = screen.frame.width - topLeftNotchpadding - topRightNotchpadding + 4
        }

        // Check if the Mac has a notch
        if screen.safeAreaInsets.top > 0 {
            // This is a display WITH a notch - use notch height settings
            notchHeight = Defaults[.notchHeight]
            if Defaults[.notchHeightMode] == .matchRealNotchSize {
                notchHeight = screen.safeAreaInsets.top
            } else if Defaults[.notchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        } else {
            // This is a display WITHOUT a notch - use non-notch height settings
            notchHeight = Defaults[.nonNotchHeight]
            if Defaults[.nonNotchHeightMode] == .matchMenuBar {
                notchHeight = screen.frame.maxY - screen.visibleFrame.maxY
            }
        }
    }

    return .init(width: notchWidth, height: notchHeight)
}
