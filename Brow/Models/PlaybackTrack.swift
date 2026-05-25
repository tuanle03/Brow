//
//  PlaybackTrack.swift
//  Brow
//

import Foundation

struct PlaybackTrack: Equatable, Sendable {
    var title: String
    var artist: String
    var album: String
    var artworkData: Data?
    var isPlaying: Bool
    var duration: TimeInterval?
    var elapsed: TimeInterval?
    var sourceBundleID: String?

    var hasContent: Bool {
        !title.isEmpty || !artist.isEmpty
    }
}
