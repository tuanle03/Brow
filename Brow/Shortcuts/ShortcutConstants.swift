//
//  Constants.swift
//  Brow
//
//  Created by Richard Kunkli on 16/08/2024.
//

import KeyboardShortcuts
import SwiftUI

extension KeyboardShortcuts.Name {
    static let clipboardHistoryPanel = Self("clipboardHistoryPanel", default: .init(.c, modifiers: [.shift, .command]))
    static let toggleMicrophone = Self("toggleMicrophone", default: .init(.f5, modifiers: [.function]))
    static let decreaseBacklight = Self("decreaseBacklight", default: .init(.f1, modifiers: [.command]))
    static let increaseBacklight = Self("increaseBacklight", default: .init(.f2, modifiers: [.command]))
    static let toggleSneakPeek = Self("toggleSneakPeek", default: .init(.h, modifiers: [.command, .shift]))
    static let toggleNotchOpen = Self("toggleNotchOpen", default: .init(.i, modifiers: [.command, .shift]))
    // AI Sessions — resolve the head of the pending Claude Code approval queue.
    static let aiApprovalAllow       = Self("aiApprovalAllow",       default: .init(.return, modifiers: [.command]))
    static let aiApprovalAllowAlways = Self("aiApprovalAllowAlways", default: .init(.return, modifiers: [.command, .shift]))
    static let aiApprovalDeny        = Self("aiApprovalDeny",        default: .init(.escape, modifiers: [.command]))
    // External displays — matched in MediaKeyInterceptor's event tap, never
    // registered as Carbon hotkeys (so bare F-keys and autorepeat work).
    static let displayBrightnessDown = Self("displayBrightnessDown", default: .init(.f1))
    static let displayBrightnessUp   = Self("displayBrightnessUp",   default: .init(.f2))
    static let displayVolumeMute     = Self("displayVolumeMute",     default: .init(.f10))
    static let displayVolumeDown     = Self("displayVolumeDown",     default: .init(.f11))
    static let displayVolumeUp       = Self("displayVolumeUp",       default: .init(.f12))
}
