//
//  MediaControllerProtocol.swift
//  Brow
//

import Foundation

protocol MediaController: AnyObject, Sendable {
    /// Bundle identifier of the underlying media source (e.g. "com.apple.Music").
    var bundleIdentifier: String { get }

    /// `true` if the underlying source is reachable (app running, or framework loaded).
    var isRunning: Bool { get }

    func fetchTrack() async -> PlaybackTrack?
    func togglePlayPause() async
    func nextTrack() async
    func previousTrack() async
}
