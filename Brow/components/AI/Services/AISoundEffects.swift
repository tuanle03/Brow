import AppKit
import Defaults
import Foundation

/// Tiny wrapper around `NSSound` so the AI panel can chirp on important
/// state transitions. Uses the bundled macOS system sounds rather than
/// shipping custom files — keeps the binary impact at zero and the
/// "8-bit-ish" character users expect. Disabled by default; toggle lives
/// in Settings → AI.
@MainActor
enum AISoundEffects {

    enum Event {
        /// A new permission request arrived. Loudest sound — user needs
        /// to look at the notch.
        case approvalArrived
        /// A toast notification just popped (Notification / Stop hook).
        case notification
        /// User clicked a row to jump back to a terminal.
        case jump
        /// Jump failed (terminal not running). Played in addition to a
        /// toast so the user knows something went wrong without reading.
        case jumpFailed
    }

    /// Play the system sound mapped to `event`, if the user opted in.
    /// No-op when the global toggle is off. Wraps `NSSound.play()` which
    /// dispatches its own audio queue, so callers don't need to await.
    static func play(_ event: Event) {
        guard Defaults[.aiSoundEffectsEnabled] else { return }
        // Sound choice rationale: short, chiptune-adjacent system sounds
        // that scale by perceived urgency.
        let name: String
        switch event {
        case .approvalArrived: name = "Blow"
        case .notification:    name = "Pop"
        case .jump:            name = "Tink"
        case .jumpFailed:      name = "Funk"
        }
        NSSound(named: NSSound.Name(name))?.play()
    }
}
