import Foundation

/// One "always allow" rule Claude Code offers alongside a permission ask
/// (its `permission_suggestions` — addRules for a tool/path, or setMode for
/// e.g. acceptEdits). This is the clean Sendable domain shape the session
/// reducer holds; `PermissionSuggestion` in `ClaudeCodeEvent.swift` is the
/// raw hook-JSON decode this gets built from.
struct ClaudePermissionUpdate: Codable, Sendable, Equatable {
    var type: String
    var destination: String?
    var behavior: String?
    var rules: [Rule]?
    var mode: String?

    struct Rule: Codable, Sendable, Equatable {
        var toolName: String?
        var ruleContent: String?
    }
}

/// A pending "may I run this tool" ask attached to an `AgentSession` while
/// its phase is `.waitingForApproval`.
struct PermissionRequest: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var toolName: String
    var toolInput: [String: AnyJSON]?
    var toolUseID: String?
    /// Claude's "always allow" suggestions, offered as extra buttons
    /// between Allow and Deny.
    var suggestedUpdates: [ClaudePermissionUpdate]
}

/// The user's answer to a `PermissionRequest`, sent back to the agent.
enum PermissionResolution: Sendable {
    case allowOnce(updatedInput: AnyJSON? = nil, updatedPermissions: [ClaudePermissionUpdate] = [])
    case deny(message: String? = nil, interrupt: Bool = false)
}
