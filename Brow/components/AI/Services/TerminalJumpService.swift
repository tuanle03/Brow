import AppKit
import Foundation

/// Brings the terminal an AI session was launched from back to the
/// foreground when the user clicks a row in the panel. Best-effort by
/// design — different terminals expose wildly different scripting
/// surfaces, and we don't bookkeep per-window/tab session ids yet, so
/// "activate the app" is the strongest universal action.
///
/// Per-terminal nuance:
/// - **iTerm2** has a full AppleScript dictionary (sessions, windows,
///   tabs) but Claude Code doesn't carry an iTerm session id, so we'd
///   still be picking the frontmost window guess. Stick with plain
///   activation for v1.
/// - **Terminal.app** is similar.
/// - **Warp** has no scripting dictionary; only `warp://` URL scheme is
///   *new* tab, which is the opposite of "jump". Plain activation again.
/// - **Ghostty** has neither AppleScript nor a URL scheme — activation
///   is literally all we can do.
///
/// When the captured hint doesn't match a running app (terminal was
/// closed, Brow restarted after capture is lost) the call is a no-op.
/// Future PR can surface a small toast in that case.
@MainActor
enum TerminalJumpService {

    /// Try to activate the terminal that owns `task`. Plays a chiptune
    /// confirmation on success and a failure tone + transient toast when
    /// the captured terminal isn't running. Returns the outcome so
    /// callers (UI tests, future automation) can branch on it.
    @discardableResult
    static func jump(to task: AITask) -> Bool {
        guard let hint = task.terminalAppHint, !hint.isEmpty else {
            ClaudeCodeStore.shared.surfaceLocalNotice("No terminal recorded for this session")
            AISoundEffects.play(.jumpFailed)
            return false
        }
        guard let app = findApp(matching: hint) else {
            ClaudeCodeStore.shared.surfaceLocalNotice("\(hint) isn't running")
            AISoundEffects.play(.jumpFailed)
            return false
        }
        activate(app)
        AISoundEffects.play(.jump)
        return true
    }

    // MARK: - Internals

    /// Matches the captured hint against the localized name or bundle id
    /// of every running app. We compare both so a future PR that switches
    /// `SessionState.terminalAppHint` to store the bundle id (more stable
    /// across locales) won't need to be re-wired here.
    private static func findApp(matching hint: String) -> NSRunningApplication? {
        let running = NSWorkspace.shared.runningApplications
        return running.first { app in
            if let name = app.localizedName, name == hint { return true }
            if let bundle = app.bundleIdentifier, bundle == hint { return true }
            return false
        }
    }

    private static func activate(_ app: NSRunningApplication) {
        if #available(macOS 14.0, *) {
            app.activate()
        } else {
            app.activate(options: [.activateAllWindows])
        }
    }
}
