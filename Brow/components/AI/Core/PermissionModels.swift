import Foundation

// MARK: - ClaudePermissionUpdate and its typed building blocks
//
// Ported field-for-field from Open Island's `ClaudeHooks.swift` (the
// "always allow" rules Claude Code offers alongside a permission ask, and
// the Codable shape Brow round-trips back to Claude Code's `hookSpecificOutput`).

enum ClaudePermissionMode: String, Codable, Sendable {
    case `default`
    case acceptEdits
    case plan
    case dontAsk
    case bypassPermissions
    case auto
}

enum ClaudePermissionBehavior: String, Codable, Sendable {
    case allow
    case deny
    case ask
}

enum ClaudePermissionUpdateDestination: String, Codable, Sendable {
    case userSettings
    case projectSettings
    case localSettings
    case session
    case cliArg
}

struct ClaudePermissionRuleValue: Equatable, Codable, Sendable {
    var toolName: String
    var ruleContent: String?

    init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }
}

enum ClaudePermissionUpdate: Equatable, Codable, Sendable {
    case addRules(destination: ClaudePermissionUpdateDestination, rules: [ClaudePermissionRuleValue], behavior: ClaudePermissionBehavior)
    case replaceRules(destination: ClaudePermissionUpdateDestination, rules: [ClaudePermissionRuleValue], behavior: ClaudePermissionBehavior)
    case removeRules(destination: ClaudePermissionUpdateDestination, rules: [ClaudePermissionRuleValue], behavior: ClaudePermissionBehavior)
    case setMode(destination: ClaudePermissionUpdateDestination, mode: ClaudePermissionMode)
    case addDirectories(destination: ClaudePermissionUpdateDestination, directories: [String])
    case removeDirectories(destination: ClaudePermissionUpdateDestination, directories: [String])

    private enum CodingKeys: String, CodingKey {
        case type
        case destination
        case rules
        case behavior
        case mode
        case directories
    }

    private enum UpdateType: String, Codable {
        case addRules
        case replaceRules
        case removeRules
        case setMode
        case addDirectories
        case removeDirectories
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(UpdateType.self, forKey: .type)
        let destination = try container.decode(ClaudePermissionUpdateDestination.self, forKey: .destination)

        switch type {
        case .addRules:
            self = .addRules(
                destination: destination,
                rules: try container.decode([ClaudePermissionRuleValue].self, forKey: .rules),
                behavior: try container.decode(ClaudePermissionBehavior.self, forKey: .behavior)
            )
        case .replaceRules:
            self = .replaceRules(
                destination: destination,
                rules: try container.decode([ClaudePermissionRuleValue].self, forKey: .rules),
                behavior: try container.decode(ClaudePermissionBehavior.self, forKey: .behavior)
            )
        case .removeRules:
            self = .removeRules(
                destination: destination,
                rules: try container.decode([ClaudePermissionRuleValue].self, forKey: .rules),
                behavior: try container.decode(ClaudePermissionBehavior.self, forKey: .behavior)
            )
        case .setMode:
            self = .setMode(
                destination: destination,
                mode: try container.decode(ClaudePermissionMode.self, forKey: .mode)
            )
        case .addDirectories:
            self = .addDirectories(
                destination: destination,
                directories: try container.decode([String].self, forKey: .directories)
            )
        case .removeDirectories:
            self = .removeDirectories(
                destination: destination,
                directories: try container.decode([String].self, forKey: .directories)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .addRules(destination, rules, behavior):
            try container.encode(UpdateType.addRules, forKey: .type)
            try container.encode(destination, forKey: .destination)
            try container.encode(rules, forKey: .rules)
            try container.encode(behavior, forKey: .behavior)
        case let .replaceRules(destination, rules, behavior):
            try container.encode(UpdateType.replaceRules, forKey: .type)
            try container.encode(destination, forKey: .destination)
            try container.encode(rules, forKey: .rules)
            try container.encode(behavior, forKey: .behavior)
        case let .removeRules(destination, rules, behavior):
            try container.encode(UpdateType.removeRules, forKey: .type)
            try container.encode(destination, forKey: .destination)
            try container.encode(rules, forKey: .rules)
            try container.encode(behavior, forKey: .behavior)
        case let .setMode(destination, mode):
            try container.encode(UpdateType.setMode, forKey: .type)
            try container.encode(destination, forKey: .destination)
            try container.encode(mode, forKey: .mode)
        case let .addDirectories(destination, directories):
            try container.encode(UpdateType.addDirectories, forKey: .type)
            try container.encode(destination, forKey: .destination)
            try container.encode(directories, forKey: .directories)
        case let .removeDirectories(destination, directories):
            try container.encode(UpdateType.removeDirectories, forKey: .type)
            try container.encode(destination, forKey: .destination)
            try container.encode(directories, forKey: .directories)
        }
    }

    /// Human-readable label for rendering as a button in the approval card.
    /// Matches Claude Code's actual option text as closely as possible.
    var displayLabel: String {
        switch self {
        case let .addRules(destination, rules, _):
            guard let rule = rules.first else { return "Yes, always allow" }
            let action = Self.actionVerb(for: rule.toolName)
            let path = Self.shortenedPath(rule.ruleContent)
            let scope = Self.scopeLabel(for: destination)
            if let path {
                return scope.isEmpty
                    ? "Yes, allow \(action) \(path)"
                    : "Yes, allow \(action) \(path) \(scope)"
            }
            return scope.isEmpty
                ? "Yes, always allow \(rule.toolName)"
                : "Yes, always allow \(rule.toolName) \(scope)"
        case let .setMode(_, mode):
            switch mode {
            case .acceptEdits:
                return "Yes, manually approve edits"
            case .bypassPermissions, .dontAsk:
                return "Yes, and bypass permissions"
            case .plan:
                return "Plan Mode"
            case .default:
                return "Manual Mode"
            case .auto:
                return "Auto Mode"
            }
        case .replaceRules:
            return "Update Rules"
        case .removeRules:
            return "Remove Rules"
        case .addDirectories:
            return "Add Directories"
        case .removeDirectories:
            return "Remove Directories"
        }
    }

    private static func actionVerb(for toolName: String) -> String {
        switch toolName {
        case "Read": return "reading from"
        case "Write", "Edit": return "writing to"
        case "Bash": return "running"
        case "Glob", "Grep": return "searching"
        default: return toolName.lowercased()
        }
    }

    private static func shortenedPath(_ ruleContent: String?) -> String? {
        guard let content = ruleContent, !content.isEmpty else { return nil }
        // Strip leading slashes and glob suffixes for cleaner display
        var path = content
        while path.hasPrefix("/") { path = String(path.dropFirst()) }
        if path.hasSuffix("/**") { path = String(path.dropLast(3)) }
        return path.isEmpty ? nil : path + "/"
    }

    private static func scopeLabel(for destination: ClaudePermissionUpdateDestination) -> String {
        switch destination {
        case .projectSettings: return "from this project"
        case .userSettings: return "globally"
        case .localSettings: return ""
        case .session: return "for this session"
        case .cliArg: return ""
        }
    }
}

// MARK: - PermissionRequest

/// A pending "may I run this tool" ask attached to an `AgentSession` while
/// its phase is `.waitingForApproval`. `title`/`summary`/`affectedPath`/
/// `primaryActionTitle`/`secondaryActionTitle` are pre-formatted for direct
/// display in the approval card (ported from Open Island's
/// `AgentSession.PermissionRequest`).
struct PermissionRequest: Codable, Sendable, Equatable, Identifiable {
    var id: String
    var title: String
    var summary: String
    var affectedPath: String
    var primaryActionTitle: String
    var secondaryActionTitle: String
    var toolName: String?
    var toolInput: [String: AnyJSON]?
    var toolUseID: String?
    /// Claude's "always allow" suggestions, offered as extra buttons
    /// between Allow and Deny.
    var suggestedUpdates: [ClaudePermissionUpdate]
    var requiresTerminalApproval: Bool

    init(
        id: String,
        title: String,
        summary: String,
        affectedPath: String,
        primaryActionTitle: String = "Allow",
        secondaryActionTitle: String = "Deny",
        toolName: String? = nil,
        toolInput: [String: AnyJSON]? = nil,
        toolUseID: String? = nil,
        suggestedUpdates: [ClaudePermissionUpdate] = [],
        requiresTerminalApproval: Bool = false
    ) {
        self.id = id
        self.title = title
        self.summary = summary
        self.affectedPath = affectedPath
        self.primaryActionTitle = primaryActionTitle
        self.secondaryActionTitle = secondaryActionTitle
        self.toolName = toolName
        self.toolInput = toolInput
        self.toolUseID = toolUseID
        self.suggestedUpdates = suggestedUpdates
        self.requiresTerminalApproval = requiresTerminalApproval
    }
}

/// The user's answer to a `PermissionRequest`, sent back to the agent.
enum PermissionResolution: Sendable {
    case allowOnce(updatedInput: AnyJSON? = nil, updatedPermissions: [ClaudePermissionUpdate] = [])
    case deny(message: String? = nil, interrupt: Bool = false)
}
