import Foundation

/// Minimal set of Claude Code hook events Brow understands. The hook script
/// posts JSON to the local HTTP server, which decodes into one of these.
///
/// MVP scope: PreToolUse + Notification. Other hook types from the Claude Code
/// spec (PostToolUse, Stop, SubagentStop, ...) parse into `.unknown` so we
/// don't drop them on the floor while still being able to log them.
enum ClaudeCodeEvent: Equatable {
    case preToolUse(PreToolUsePayload)
    case notification(NotificationPayload)
    case unknown(name: String, rawJSON: String)

    var hookName: String {
        switch self {
        case .preToolUse:   return "PreToolUse"
        case .notification: return "Notification"
        case .unknown(let n, _): return n
        }
    }
}

struct PreToolUsePayload: Codable, Equatable {
    let sessionID: String?
    let toolName: String
    let toolInput: [String: AnyJSON]?
    let projectDirectory: String?
    let cwd: String?

    enum CodingKeys: String, CodingKey {
        case sessionID         = "session_id"
        case toolName          = "tool_name"
        case toolInput         = "tool_input"
        case projectDirectory  = "project_dir"
        case cwd
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
        case "PreToolUse":
            if let payload = try? decoder.decode(PreToolUsePayload.self, from: data) {
                event = .preToolUse(payload)
            } else {
                event = .unknown(name: name, rawJSON: rawString)
            }
        case "Notification":
            if let payload = try? decoder.decode(NotificationPayload.self, from: data) {
                event = .notification(payload)
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
