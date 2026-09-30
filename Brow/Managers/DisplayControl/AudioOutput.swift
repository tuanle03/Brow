//
//  AudioOutput.swift
//  Brow
//

import Foundation

struct AudioOutputInfo: Equatable {
    let name: String
    /// HDMI or DisplayPort transport — audio carried to a monitor.
    let isDisplayAudio: Bool
}
