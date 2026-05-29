import Foundation

/// Hook events Brow subscribes to. The hook script posts JSON to the local
/// HTTP server, which decodes into one of these.
///
/// `PermissionRequest` is the event that fires when Claude Code would
/// otherwise show its native permission dialog — exactly the moments we
/// want the notch to take over. `Notification` covers the "Claude is
/// waiting / idle" alerts. Anything else parses into `.unknown` so we can
/// still log it without dropping it.
enum ClaudeCodeEvent: Equatable {
    case sessionStart(SessionStartPayload)
    case sessionEnd(SessionEndPayload)
    case userPromptSubmit(UserPromptSubmitPayload)
    case permissionRequest(PermissionRequestPayload)
    case notification(NotificationPayload)
    case stop(StopPayload)
    case unknown(name: String, rawJSON: String)

    var hookName: String {
        switch self {
        case .sessionStart:      return "SessionStart"
        case .sessionEnd:        return "SessionEnd"
        case .userPromptSubmit:  return "UserPromptSubmit"
        case .permissionRequest: return "PermissionRequest"
        case .notification:      return "Notification"
        case .stop:              return "Stop"
        case .unknown(let n, _): return n
        }
    }
}

struct PermissionRequestPayload: Codable, Equatable {
    let sessionID: String?
    let toolName: String
    let toolInput: [String: AnyJSON]?
    let toolUseID: String?
    let projectDirectory: String?
    let cwd: String?
    let permissionMode: String?
    /// Claude Code's "Yes, allow X / Switch to acceptEdits / …" entries. Each
    /// suggestion maps to one extra button between "Allow" and "Deny", so
    /// the notch UI can mirror the CLI prompt exactly. Optional because not
    /// every PermissionRequest carries them.
    let permissionSuggestions: [PermissionSuggestion]?

    enum CodingKeys: String, CodingKey {
        case sessionID             = "session_id"
        case toolName              = "tool_name"
        case toolInput             = "tool_input"
        case toolUseID             = "tool_use_id"
        case projectDirectory      = "project_dir"
        case cwd
        case permissionMode        = "permission_mode"
        case permissionSuggestions = "permission_suggestions"
    }
}

/// One row from Claude Code's `permission_suggestions` array. Either an
/// `addRules` suggestion ("always allow this tool in this folder / for
/// this exact command") or a `setMode` suggestion ("switch to acceptEdits
/// mode"). Brow round-trips the original JSON back to Claude Code via
/// `updatedPermissions` when the user picks one.
struct PermissionSuggestion: Codable, Equatable, Identifiable {
    var id: String { "\(type)|\(destination ?? "")|\(behavior ?? "")|\(mode ?? "")|\(rulesSignature)" }

    let type: String              // "addRules" | "setMode"
    let destination: String?      // "session" | "localSettings"
    let behavior: String?         // "allow" (for addRules)
    let rules: [Rule]?
    let mode: String?             // e.g. "acceptEdits" (for setMode)

    struct Rule: Codable, Equatable, Hashable {
        let toolName: String?
        let ruleContent: String?
    }

    private var rulesSignature: String {
        guard let rules else { return "" }
        return rules.map { "\($0.toolName ?? "")=\($0.ruleContent ?? "")" }.joined(separator: ",")
    }

    /// User-facing label, mirroring how Claude Code labels each numbered
    /// option in the CLI. Heuristics ported from Masko's implementation.
    var displayLabel: String {
        switch type {
        case "addRules":
            guard let firstRule = rules?.first else { return "Always allow" }
            let toolName = firstRule.toolName ?? "tool"
            let ruleContent = firstRule.ruleContent ?? ""
            if ruleContent.contains("**") {
                let short = (ruleContent.replacingOccurrences(of: "/**", with: "") as NSString).lastPathComponent
                return "Allow \(toolName) in \(short)/"
            } else if !ruleContent.isEmpty {
                let trimmed = ruleContent.count > 28
                    ? String(ruleContent.prefix(25)) + "…"
                    : ruleContent
                return "Always allow `\(trimmed)`"
            }
            return "Always allow \(toolName)"
        case "setMode":
            switch mode {
            case "acceptEdits": return "Auto-accept edits"
            case "plan":        return "Switch to plan mode"
            default:            return mode.map { "Set mode: \($0)" } ?? "Set mode"
            }
        default:
            return type
        }
    }

    /// Re-encode back to the dict shape Claude Code expects in the
    /// `updatedPermissions` response field.
    var asResponseDict: [String: Any] {
        var d: [String: Any] = ["type": type]
        if let destination { d["destination"] = destination }
        if let behavior    { d["behavior"]    = behavior }
        if let mode        { d["mode"]        = mode }
        if let rules {
            d["rules"] = rules.map { rule -> [String: String] in
                var r: [String: String] = [:]
                if let t = rule.toolName    { r["toolName"]    = t }
                if let c = rule.ruleContent { r["ruleContent"] = c }
                return r
            }
        }
        return d
    }
}

struct NotificationPayload: Codable, Equatable {
    let sessionID: String?
    let message: String
    let projectDirectory: String?

    enum CodingKeys: String, CodingKey {
        case sessionID        = "session_id"
        case message
        case projectDirectory = "project_dir"
    }
}

/// Fires when a Claude Code session begins (new, resumed, or post-compact).
/// Brow uses this to populate the Sessions list the instant a CLI session
/// starts, instead of waiting for the first permission/notification event.
struct SessionStartPayload: Codable, Equatable {
    let sessionID: String?
    let cwd: String?
    let projectDirectory: String?
    /// "startup" | "resume" | "clear" | "compact"
    let source: String?
    let model: String?

    enum CodingKeys: String, CodingKey {
        case sessionID         = "session_id"
        case cwd
        case projectDirectory  = "project_dir"
        case source
        case model
    }
}

/// Fires when a session terminates (logout, /clear, exit, …). Brow removes
/// it from the Sessions list so the notch shows current state.
struct SessionEndPayload: Codable, Equatable {
    let sessionID: String?
    let cwd: String?
    let projectDirectory: String?
    /// "clear" | "resume" | "logout" | "prompt_input_exit" | "bypass_permissions_disabled" | "other"
    let reason: String?

    enum CodingKeys: String, CodingKey {
        case sessionID         = "session_id"
        case cwd
        case projectDirectory  = "project_dir"
        case reason
    }
}

/// Fires every time the user submits a prompt to Claude Code. Brow uses
/// the latest prompt as the "You: …" subtitle in the Monitor row so the
/// task list reads like a TODO list of asks. Only the text is meaningful
/// for us; we don't echo anything back to Claude.
struct UserPromptSubmitPayload: Codable, Equatable {
    let sessionID: String?
    let prompt: String
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case prompt
        case cwd
    }
}

/// Fires when Claude finishes its response and yields back to the user.
/// Claude Code does not include a user-facing message here, so the toast
/// Brow shows is generic ("Claude is done"). `cwd` lets us label the toast
/// with the project the response came from.
struct StopPayload: Codable, Equatable {
    let sessionID: String?
    let cwd: String?
    let projectDirectory: String?

    enum CodingKeys: String, CodingKey {
        case sessionID         = "session_id"
        case cwd
        case projectDirectory  = "project_dir"
    }
}

/// Bridges arbitrary JSON values from hook payloads — Claude Code's
/// `tool_input` can hold strings, numbers, bools, nested objects, arrays.
/// We don't need to interpret most of it yet; we just need to preserve and
/// echo it back. AnyJSON keeps decode/encode round-tripping safe.
enum AnyJSON: Codable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: AnyJSON])
    case array([AnyJSON])
    case null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Bool.self)              { self = .bool(v); return }
        if let v = try? c.decode(Int.self)               { self = .int(v); return }
        if let v = try? c.decode(Double.self)            { self = .double(v); return }
        if let v = try? c.decode(String.self)            { self = .string(v); return }
        if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
        if let v = try? c.decode([AnyJSON].self)         { self = .array(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:           try c.encodeNil()
        case .bool(let v):    try c.encode(v)
        case .int(let v):     try c.encode(v)
        case .double(let v):  try c.encode(v)
        case .string(let v):  try c.encode(v)
        case .object(let v):  try c.encode(v)
        case .array(let v):   try c.encode(v)
        }
    }

    /// Best-effort short rendering for UI / logs (e.g. "Bash" tool's command
    /// argument). Falls back to JSON for non-string values.
    var asDisplayString: String {
        switch self {
        case .string(let s): return s
        case .int(let i):    return "\(i)"
        case .double(let d): return "\(d)"
        case .bool(let b):   return "\(b)"
        case .null:          return "null"
        case .array, .object:
            let enc = JSONEncoder()
            enc.outputFormatting = []
            return (try? String(data: enc.encode(self), encoding: .utf8)) ?? "?"
        }
    }
}

/// Decoded shell wrapper around an incoming event. Carries the raw JSON
/// string so the debug Settings panel can echo it verbatim for diagnosing
/// hook-script issues.
struct ClaudeCodeIncomingEvent {
    let receivedAt: Date
    let hookName: String
    let event: ClaudeCodeEvent
    let rawJSON: String

    static func decode(from data: Data) -> ClaudeCodeIncomingEvent? {
        guard let rawString = String(data: data, encoding: .utf8) else { return nil }
        let decoder = JSONDecoder()
        struct Envelope: Decodable { let hook_event_name: String? }
        guard let envelope = try? decoder.decode(Envelope.self, from: data) else {
            return ClaudeCodeIncomingEvent(
                receivedAt: Date(),
                hookName: "unknown",
                event: .unknown(name: "unknown", rawJSON: rawString),
                rawJSON: rawString
            )
        }
        let name = envelope.hook_event_name ?? "unknown"
        let event: ClaudeCodeEvent
        switch name {
        case "SessionStart":
            if let payload = try? decoder.decode(SessionStartPayload.self, from: data) {
                event = .sessionStart(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        case "SessionEnd":
            if let payload = try? decoder.decode(SessionEndPayload.self, from: data) {
                event = .sessionEnd(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        case "UserPromptSubmit":
            if let payload = try? decoder.decode(UserPromptSubmitPayload.self, from: data) {
                event = .userPromptSubmit(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        case "PermissionRequest":
            if let payload = try? decoder.decode(PermissionRequestPayload.self, from: data) {
                event = .permissionRequest(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        case "Notification":
            if let payload = try? decoder.decode(NotificationPayload.self, from: data) {
                event = .notification(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        case "Stop":
            if let payload = try? decoder.decode(StopPayload.self, from: data) {
                event = .stop(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        default:
            event = .unknown(name: name, rawJSON: rawString)
        }
        return ClaudeCodeIncomingEvent(
            receivedAt: Date(),
            hookName: name,
            event: event,
            rawJSON: rawString
        )
    }
}
