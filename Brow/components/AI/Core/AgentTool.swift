import SwiftUI

/// Which coding agent a session belongs to. Kept open (not `Codable` raw
/// string matching alone) so a later agent (e.g. Cursor CLI) is a one-case
/// addition, not a redesign.
enum AgentTool: String, Codable, Sendable, Equatable, CaseIterable {
    case claudeCode, codex

    var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    var shortName: String { self == .claudeCode ? "Claude" : "Codex" }
    var brandColorHex: String { self == .claudeCode ? "d97742" : "4aa3df" }
    var isClaudeCodeFork: Bool { self == .claudeCode }
}
