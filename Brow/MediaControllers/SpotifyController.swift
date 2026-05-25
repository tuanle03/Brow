//
//  SpotifyController.swift
//  Brow
//

import Foundation

final class SpotifyController: AppleScriptMediaController, @unchecked Sendable {
    init() {
        super.init(bundleIdentifier: "com.spotify.client", appName: "Spotify")
    }
}
