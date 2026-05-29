import Foundation
import SwiftUI

/// Unified, UI-facing model for one in-flight (or recently-finished) AI
/// agent task. Built on top of the underlying `ClaudeCodeStore` (the only
/// adapter we ship today). The model is deliberately agent-agnostic so the
/// same panel can render Codex / Gemini / Cursor sessions once their
/// adapters land — see `AIAgentKind`.
struct AITask: Identifiable, Equatable {
    let id: String                  // = sessionID (Claude Code) for v1
    let agentKind: AIAgentKind
    let sessionID: String?
    let projectDirectory: String?
    /// Optional bundle id or display name of the terminal the agent was
    /// launched from (e.g. "com.googlecode.iterm2", "Ghostty"). Captured
    /// best-effort at SessionStart; nil when unknown. Drives the Jump
    /// button copy ("Jump to iTerm2").
    let terminalAppHint: String?
    /// First user message of the session — surfaced as the row's subtitle
    /// ("You: fix the auth bug in middleware"). nil until the first
    /// UserPromptSubmit hook fires (PR B).
    let userPrompt: String?
    let status: AITaskStatus
    let lastActivityAt: Date
    /// Set when `status == .pendingApproval` so the Approve section can
    /// render the diff / command + the per-suggestion buttons.
    let currentApproval: PendingApproval?
    /// Set when `status == .askingQuestion`.
    let currentQuestion: AIQuestion?
}

/// Which AI coding agent owns the task. v1 only emits `.claudeCode`; the
/// pill / tint mappings here mirror the AgentIsland visual language so
/// future adapters slot in without UI changes.
enum AIAgentKind: String, CaseIterable, Equatable {
    case claudeCode
    case codex
    case geminiCLI
    case cursor
    case opencode
    case copilot

    var displayName: String {
        switch self {
        case .claudeCode: return "Claude"
        case .codex:      return "Codex"
        case .geminiCLI:  return "Gemini"
        case .cursor:     return "Cursor"
        case .opencode:   return "OpenCode"
        case .copilot:    return "Copilot"
        }
    }

    var symbolName: String {
        switch self {
        case .claudeCode: return "sparkles"
        case .codex:      return "chevron.left.forwardslash.chevron.right"
        case .geminiCLI:  return "diamond.fill"
        case .cursor:     return "cursorarrow.rays"
        case .opencode:   return "curlybraces"
        case .copilot:    return "airplane"
        }
    }

    var tint: Color {
        switch self {
        case .claudeCode: return Color(red: 0.95, green: 0.55, blue: 0.35)
        case .codex:      return Color(red: 0.40, green: 0.85, blue: 0.55)
        case .geminiCLI:  return Color(red: 0.45, green: 0.65, blue: 1.00)
        case .cursor:     return Color(red: 0.80, green: 0.80, blue: 0.85)
        case .opencode:   return Color(red: 0.95, green: 0.45, blue: 0.85)
        case .copilot:    return Color(red: 0.55, green: 0.85, blue: 0.95)
        }
    }
}

/// The lifecycle phase of a task as seen by the panel. Ordered by visual
/// priority — `pendingApproval` and `askingQuestion` block on the user,
/// so the registry surfaces them above everything else.
enum AITaskStatus: Equatable {
    case idle
    case working(String?)          // associated value = optional inline body ("Writing middleware.ts")
    case done(String?)             // ditto ("Done — click to jump")
    case pendingApproval
    case askingQuestion

    /// Inline status line under the task title in the highlighted row.
    /// `nil` for idle / collapsed rows that should only show a dot.
    var bodyText: String? {
        switch self {
        case .working(let s): return s
        case .done(let s):    return s
        case .pendingApproval: return "Waiting on approval"
        case .askingQuestion:  return "Claude is asking a question"
        case .idle:            return nil
        }
    }

    var bodyColor: Color {
        switch self {
        case .working, .pendingApproval, .askingQuestion:
            return Color(red: 0.40, green: 0.65, blue: 1.00)
        case .done:
            return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .idle:
            return .white.opacity(0.55)
        }
    }

    /// Color of the small dot in collapsed rows (Monitor / Jump).
    var dotColor: Color {
        switch self {
        case .working, .pendingApproval, .askingQuestion:
            return Color(red: 0.40, green: 0.65, blue: 1.00)
        case .done:
            return Color(red: 0.45, green: 0.85, blue: 0.55)
        case .idle:
            return .white.opacity(0.4)
        }
    }
}

/// Which sub-view the panel should render. Derived from the registry's
/// `tasks` — the UI never sets this directly.
enum AIPanelMode: Equatable {
    case monitor                    // no blocking state — show task list
    case approve(taskID: String)    // a task has `pendingApproval`
    case ask(taskID: String)        // a task has `askingQuestion`
    case jump                       // user clicked a row; placeholder for future
}

/// Decoded `AskUserQuestion` payload. v1 surfaces this as a notification
/// because the Claude Code hook API only round-trips allow/deny, not
/// arbitrary answers — but storing the structured options now means PR D
/// can flip it interactive without re-decoding.
struct AIQuestion: Equatable {
    let text: String
    let options: [Option]

    struct Option: Identifiable, Equatable {
        let id: String              // shortcut label ("K1", "K2", …)
        let label: String
    }
}
