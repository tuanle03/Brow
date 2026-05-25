//
//  MediaRemoteController.swift
//  Brow
//
//  Bridges the private `MediaRemote.framework` via `dlopen`/`dlsym`. On macOS
//  builds where the framework still exposes now-playing info this returns
//  system-wide playback data (works for Spotify, Apple Music, Safari, etc.).
//  On macOS 15.4+ Apple started restricting access — when the framework
//  returns empty data we fall back to per-app AppleScript controllers.
//

import AppKit
import Foundation

final class MediaRemoteController: MediaController, @unchecked Sendable {
    let bundleIdentifier = "com.apple.mediaremote"

    private typealias GetNowPlayingInfoFn =
        @convention(c) (DispatchQueue, @escaping ([String: Any]) -> Void) -> Void
    private typealias SendCommandFn =
        @convention(c) (Int, [String: Any]?) -> Bool

    private let handle: UnsafeMutableRawPointer?
    private let getNowPlayingInfo: GetNowPlayingInfoFn?
    private let sendCommand: SendCommandFn?

    init() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        let handle = dlopen(path, RTLD_LAZY)
        self.handle = handle

        if let handle,
           let nowPlayingSym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            self.getNowPlayingInfo = unsafeBitCast(nowPlayingSym, to: GetNowPlayingInfoFn.self)
        } else {
            self.getNowPlayingInfo = nil
        }

        if let handle,
           let sendSym = dlsym(handle, "MRMediaRemoteSendCommand") {
            self.sendCommand = unsafeBitCast(sendSym, to: SendCommandFn.self)
        } else {
            self.sendCommand = nil
        }
    }

    var isRunning: Bool {
        getNowPlayingInfo != nil
    }

    func fetchTrack() async -> PlaybackTrack? {
        guard let getNowPlayingInfo else { return nil }

        return await withCheckedContinuation { continuation in
            getNowPlayingInfo(DispatchQueue.main) { info in
                let title = info["kMRMediaRemoteNowPlayingInfoTitle"] as? String ?? ""
                let artist = info["kMRMediaRemoteNowPlayingInfoArtist"] as? String ?? ""
                let album = info["kMRMediaRemoteNowPlayingInfoAlbum"] as? String ?? ""
                let artwork = info["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                let duration = info["kMRMediaRemoteNowPlayingInfoDuration"] as? Double
                let elapsed = info["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double
                let playbackRate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double ?? 0

                guard !title.isEmpty || !artist.isEmpty else {
                    continuation.resume(returning: nil)
                    return
                }

                continuation.resume(returning: PlaybackTrack(
                    title: title,
                    artist: artist,
                    album: album,
                    artworkData: artwork,
                    isPlaying: playbackRate > 0,
                    duration: duration,
                    elapsed: elapsed,
                    sourceBundleID: nil
                ))
            }
        }
    }

    func togglePlayPause() async {
        _ = sendCommand?(MediaRemoteCommand.togglePlayPause, nil)
    }

    func nextTrack() async {
        _ = sendCommand?(MediaRemoteCommand.nextTrack, nil)
    }

    func previousTrack() async {
        _ = sendCommand?(MediaRemoteCommand.previousTrack, nil)
    }

    /// MediaRemote command IDs are stable across macOS versions; values
    /// reverse-engineered from the framework's symbol headers.
    private enum MediaRemoteCommand {
        static let togglePlayPause = 2
        static let nextTrack = 4
        static let previousTrack = 5
    }
}
