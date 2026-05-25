//
//  MusicManager.swift
//  Brow
//
//  Polls the available media sources every second and publishes the best
//  current track to SwiftUI. Source priority:
//    1. MediaRemote (system-wide, works for Safari/Chrome/etc.)
//    2. Spotify (AppleScript) if running
//    3. Apple Music (AppleScript) if running
//

import AppKit
import Observation

@MainActor
@Observable
final class MusicManager {
    static let shared = MusicManager()

    private(set) var currentTrack: PlaybackTrack?
    private(set) var artworkImage: NSImage?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    @ObservationIgnored private let mediaRemote = MediaRemoteController()
    @ObservationIgnored private let appleMusic = AppleMusicController()
    @ObservationIgnored private let spotify = SpotifyController()

    private init() {}

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    func togglePlayPause() async {
        await activeController()?.togglePlayPause()
    }

    func next() async {
        await activeController()?.nextTrack()
    }

    func previous() async {
        await activeController()?.previousTrack()
    }

    // MARK: - Private

    private func poll() async {
        let track = await currentBestTrack()
        let oldArtworkData = currentTrack?.artworkData
        currentTrack = track
        if track?.artworkData != oldArtworkData {
            updateArtwork(from: track?.artworkData)
        }
        if track == nil {
            artworkImage = nil
        }
    }

    private func currentBestTrack() async -> PlaybackTrack? {
        if mediaRemote.isRunning, let track = await mediaRemote.fetchTrack(), track.hasContent {
            return track
        }
        if spotify.isRunning, let track = await spotify.fetchTrack(), track.hasContent {
            return track
        }
        if appleMusic.isRunning, let track = await appleMusic.fetchTrack(), track.hasContent {
            return track
        }
        return nil
    }

    private func updateArtwork(from data: Data?) {
        guard let data, let image = NSImage(data: data) else {
            artworkImage = nil
            return
        }
        artworkImage = image
    }

    private func activeController() -> MediaController? {
        if let id = currentTrack?.sourceBundleID {
            if id == spotify.bundleIdentifier { return spotify }
            if id == appleMusic.bundleIdentifier { return appleMusic }
        }
        return mediaRemote.isRunning ? mediaRemote : nil
    }
}
