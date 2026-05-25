//
//  AppleMusicController.swift
//  Brow
//

import Foundation

final class AppleMusicController: AppleScriptMediaController, @unchecked Sendable {
    init() {
        super.init(bundleIdentifier: "com.apple.Music", appName: "Music")
    }
}
