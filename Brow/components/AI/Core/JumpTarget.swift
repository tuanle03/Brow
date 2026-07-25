import Foundation

/// Everything `TerminalJumpService` needs to bring the terminal running an
/// agent session to the front — resolved/refreshed by
/// `TerminalJumpTargetResolver` as the session's terminal is (re)discovered.
struct JumpTarget: Codable, Sendable, Equatable {
    /// Bundle id of the terminal app (Terminal.app, iTerm2, Ghostty, VS
    /// Code, …) — `TerminalJumpService` dispatches by this.
    var terminalApp: String
    var workspaceName: String
    var paneTitle: String
    var workingDirectory: String?
    var terminalSessionID: String?
    var terminalTTY: String?
    var tmuxTarget: String?
    var tmuxSocketPath: String?
    var codexThreadID: String?
}
