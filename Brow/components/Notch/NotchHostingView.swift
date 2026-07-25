//
//  NotchHostingView.swift
//  Brow
//
//  Hosts the notch's SwiftUI content in a `BrowSkyLightWindow`
//  (`.nonactivatingPanel`, `canBecomeKey == true`). Ported from Open
//  Island's `NotchHostingView` (`OverlayPanelController.swift`).
//

import SwiftUI

final class NotchHostingView<Content: View>: NSHostingView<Content> {
    override func mouseDown(with event: NSEvent) {
        // Ensure the panel is key before SwiftUI processes the click.
        // With nonactivatingPanel, hover-opened panels aren't key, so
        // SwiftUI Button may consume the first click for key acquisition
        // instead of firing its action.
        window?.makeKey()
        super.mouseDown(with: event)
    }
}
