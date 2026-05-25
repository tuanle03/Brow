//
//  AppleScriptMediaController.swift
//  Brow
//

import AppKit
import Foundation

/// Shared base for AppleScript-driven controllers (Music + Spotify). Both apps
/// expose a near-identical scripting dictionary, so we parameterize the
/// application name + bundle identifier and reuse the script bodies.
class AppleScriptMediaController: MediaController, @unchecked Sendable {
    let bundleIdentifier: String
    let appName: String

    init(bundleIdentifier: String, appName: String) {
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
    }

    var isRunning: Bool {
        NSWorkspace.shared.runningApplications.contains {
            $0.bundleIdentifier == bundleIdentifier
        }
    }

    func fetchTrack() async -> PlaybackTrack? {
        guard isRunning else { return nil }
        return await fetchTrackImpl()
    }

    func togglePlayPause() async {
        await run(command: "playpause")
    }

    func nextTrack() async {
        await run(command: "next track")
    }

    func previousTrack() async {
        await run(command: "previous track")
    }

    // MARK: - Private

    private func fetchTrackImpl() async -> PlaybackTrack? {
        let source = """
        tell application "\(appName)"
            if it is running then
                set ps to player state as string
                if ps is "playing" or ps is "paused" then
                    set t to current track
                    set trackTitle to (get name of t)
                    set trackArtist to (get artist of t)
                    set trackAlbum to (get album of t)
                    set trackDuration to (get duration of t)
                    set playerPos to (get player position)
                    set isPlaying to (ps is "playing")
                    return trackTitle & "‖" & trackArtist & "‖" & trackAlbum & "‖" & trackDuration & "‖" & playerPos & "‖" & isPlaying
                end if
            end if
            return ""
        end tell
        """

        guard let raw = await runScript(source: source), !raw.isEmpty else {
            return nil
        }

        let parts = raw.components(separatedBy: "‖")
        guard parts.count >= 6 else { return nil }

        return PlaybackTrack(
            title: parts[0],
            artist: parts[1],
            album: parts[2],
            artworkData: nil,
            isPlaying: parts[5] == "true",
            duration: Double(parts[3]),
            elapsed: Double(parts[4]),
            sourceBundleID: bundleIdentifier
        )
    }

    private func run(command: String) async {
        let source = """
        tell application "\(appName)"
            if it is running then \(command)
        end tell
        """
        _ = await runScript(source: source)
    }

    private func runScript(source: String) async -> String? {
        await Task.detached(priority: .userInitiated) {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { return nil }
            let descriptor = script.executeAndReturnError(&error)
            if error != nil { return nil }
            return descriptor.stringValue
        }.value
    }
}
