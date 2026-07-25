import Foundation

// MARK: - Per-case payloads
//
// Ported field-for-field from Open Island's `AgentEvent.swift`, restricted
// to the Claude/Codex subset the reducer (task 1.5) and bridge (task 1.6)
// need. Dropped entirely: `geminiSessionMetadataUpdated`,
// `openCodeSessionMetadataUpdated`, `cursorSessionMetadataUpdated` — no
// gemini/openCode/cursor metadata types exist in Brow (see
// `AgentSession.swift`'s same trim). The reference's separate
// `claudeSessionMetadataUpdated` case is folded into `sessionMetadataUpdated`
// below (its payload now carries both `claudeMetadata` and `codexMetadata`,
// each optional) rather than kept as a 9th case — the brief's case list
// names only `sessionMetadataUpdated`.

/// Payload for `AgentEvent.sessionStarted`. Trimmed like `AgentSession`:
/// gemini/openCode/cursor metadata dropped.
struct SessionStarted: Equatable, Codable, Sendable {
    var sessionID: String
    var title: String
    var tool: AgentTool
    var origin: SessionOrigin?
    var initialPhase: SessionPhase
    var summary: String
    var timestamp: Date
    var jumpTarget: JumpTarget?
    var claudeMetadata: ClaudeSessionMetadata?
    var codexMetadata: CodexSessionMetadata?
    var isRemote: Bool

    init(
        sessionID: String,
        title: String,
        tool: AgentTool,
        origin: SessionOrigin? = nil,
        initialPhase: SessionPhase = .running,
        summary: String,
        timestamp: Date,
        jumpTarget: JumpTarget? = nil,
        claudeMetadata: ClaudeSessionMetadata? = nil,
        codexMetadata: CodexSessionMetadata? = nil,
        isRemote: Bool = false
    ) {
        self.sessionID = sessionID
        self.title = title
        self.tool = tool
        self.origin = origin
        self.initialPhase = initialPhase
        self.summary = summary
        self.timestamp = timestamp
        self.jumpTarget = jumpTarget
        self.claudeMetadata = claudeMetadata
        self.codexMetadata = codexMetadata
        self.isRemote = isRemote
    }
}

/// Payload for `AgentEvent.activityUpdated`. Direct port plus one additive
/// field: `title` — a project name derived from the event's `cwd`, used by the
/// reducer to backfill sessions that missed their `SessionStart` (and so still
/// carry the generic "Claude Code" fallback title). `nil` when the event
/// carried no usable cwd.
struct SessionActivityUpdated: Equatable, Codable, Sendable {
    var sessionID: String
    var summary: String
    var phase: SessionPhase
    var timestamp: Date
    var title: String?

    init(sessionID: String, summary: String, phase: SessionPhase, timestamp: Date, title: String? = nil) {
        self.sessionID = sessionID
        self.summary = summary
        self.phase = phase
        self.timestamp = timestamp
        self.title = title
    }
}

/// Payload for `AgentEvent.permissionRequested`. Direct port plus the same
/// additive `title` backfill field as `SessionActivityUpdated` (project name
/// from the request's cwd/project_dir; `nil` when unknown).
struct PermissionRequested: Equatable, Codable, Sendable {
    var sessionID: String
    var request: PermissionRequest
    var timestamp: Date
    var title: String?

    init(sessionID: String, request: PermissionRequest, timestamp: Date, title: String? = nil) {
        self.sessionID = sessionID
        self.request = request
        self.timestamp = timestamp
        self.title = title
    }
}

/// Payload for `AgentEvent.questionAsked`. Direct port, no trim.
struct QuestionAsked: Equatable, Codable, Sendable {
    var sessionID: String
    var prompt: QuestionPrompt
    var timestamp: Date

    init(sessionID: String, prompt: QuestionPrompt, timestamp: Date) {
        self.sessionID = sessionID
        self.prompt = prompt
        self.timestamp = timestamp
    }
}

/// Payload for `AgentEvent.sessionCompleted`. Direct port, no trim.
struct SessionCompleted: Equatable, Codable, Sendable {
    var sessionID: String
    var summary: String
    var timestamp: Date
    var isInterrupt: Bool?
    /// When `true`, the agent session itself has ended (e.g. Claude Code's
    /// `SessionEnd` hook). Distinguishes a full session teardown from a
    /// turn-level completion (`Stop`/`StopFailure`) where the CLI is still
    /// running and waiting for the next user prompt.
    var isSessionEnd: Bool?

    init(
        sessionID: String,
        summary: String,
        timestamp: Date,
        isInterrupt: Bool? = nil,
        isSessionEnd: Bool? = nil
    ) {
        self.sessionID = sessionID
        self.summary = summary
        self.timestamp = timestamp
        self.isInterrupt = isInterrupt
        self.isSessionEnd = isSessionEnd
    }
}

/// Payload for `AgentEvent.jumpTargetUpdated`. Direct port, no trim.
struct JumpTargetUpdated: Equatable, Codable, Sendable {
    var sessionID: String
    var jumpTarget: JumpTarget
    var timestamp: Date

    init(sessionID: String, jumpTarget: JumpTarget, timestamp: Date) {
        self.sessionID = sessionID
        self.jumpTarget = jumpTarget
        self.timestamp = timestamp
    }
}

/// Payload for `AgentEvent.sessionMetadataUpdated`. Folds the reference's
/// two separate cases (`sessionMetadataUpdated` carrying only
/// `codexMetadata`, `claudeSessionMetadataUpdated` carrying only
/// `claudeMetadata`) into one payload with both fields optional, since
/// Brow's case list (per the task brief) has a single metadata-updated case
/// covering both Claude and Codex.
struct SessionMetadataUpdated: Equatable, Codable, Sendable {
    var sessionID: String
    var claudeMetadata: ClaudeSessionMetadata?
    var codexMetadata: CodexSessionMetadata?
    var timestamp: Date

    init(
        sessionID: String,
        claudeMetadata: ClaudeSessionMetadata? = nil,
        codexMetadata: CodexSessionMetadata? = nil,
        timestamp: Date
    ) {
        self.sessionID = sessionID
        self.claudeMetadata = claudeMetadata
        self.codexMetadata = codexMetadata
        self.timestamp = timestamp
    }
}

/// Payload for `AgentEvent.actionableStateResolved`. Direct port, no trim.
struct ActionableStateResolved: Equatable, Codable, Sendable {
    var sessionID: String
    var summary: String
    var timestamp: Date

    init(sessionID: String, summary: String, timestamp: Date) {
        self.sessionID = sessionID
        self.summary = summary
        self.timestamp = timestamp
    }
}

// MARK: - AgentEvent

/// The Codable event enum the reducer (task 1.5) consumes and the bridge
/// (task 1.6) produces. Ported from Open Island's `AgentEvent`, restricted
/// to the Claude/Codex subset: dropped `claudeSessionMetadataUpdated`
/// (folded into `sessionMetadataUpdated`, see above),
/// `geminiSessionMetadataUpdated`, `openCodeSessionMetadataUpdated`,
/// `cursorSessionMetadataUpdated` (no corresponding tool support in Brow).
/// The `type`-discriminated Codable encoding is ported verbatim for the
/// cases that remain, so a future bridge emitting this wire format decodes
/// identically.
enum AgentEvent: Equatable, Codable, Sendable {
    case sessionStarted(SessionStarted)
    case activityUpdated(SessionActivityUpdated)
    case permissionRequested(PermissionRequested)
    case questionAsked(QuestionAsked)
    case sessionCompleted(SessionCompleted)
    case jumpTargetUpdated(JumpTargetUpdated)
    case sessionMetadataUpdated(SessionMetadataUpdated)
    case actionableStateResolved(ActionableStateResolved)

    private enum CodingKeys: String, CodingKey {
        case type
        case sessionStarted
        case activityUpdated
        case permissionRequested
        case questionAsked
        case sessionCompleted
        case jumpTargetUpdated
        case sessionMetadataUpdated
        case actionableStateResolved
    }

    private enum EventType: String, Codable {
        case sessionStarted
        case activityUpdated
        case permissionRequested
        case questionAsked
        case sessionCompleted
        case jumpTargetUpdated
        case sessionMetadataUpdated
        case actionableStateResolved
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(EventType.self, forKey: .type)

        switch type {
        case .sessionStarted:
            self = .sessionStarted(try container.decode(SessionStarted.self, forKey: .sessionStarted))
        case .activityUpdated:
            self = .activityUpdated(try container.decode(SessionActivityUpdated.self, forKey: .activityUpdated))
        case .permissionRequested:
            self = .permissionRequested(try container.decode(PermissionRequested.self, forKey: .permissionRequested))
        case .questionAsked:
            self = .questionAsked(try container.decode(QuestionAsked.self, forKey: .questionAsked))
        case .sessionCompleted:
            self = .sessionCompleted(try container.decode(SessionCompleted.self, forKey: .sessionCompleted))
        case .jumpTargetUpdated:
            self = .jumpTargetUpdated(try container.decode(JumpTargetUpdated.self, forKey: .jumpTargetUpdated))
        case .sessionMetadataUpdated:
            self = .sessionMetadataUpdated(
                try container.decode(SessionMetadataUpdated.self, forKey: .sessionMetadataUpdated)
            )
        case .actionableStateResolved:
            self = .actionableStateResolved(
                try container.decode(ActionableStateResolved.self, forKey: .actionableStateResolved)
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case let .sessionStarted(payload):
            try container.encode(EventType.sessionStarted, forKey: .type)
            try container.encode(payload, forKey: .sessionStarted)
        case let .activityUpdated(payload):
            try container.encode(EventType.activityUpdated, forKey: .type)
            try container.encode(payload, forKey: .activityUpdated)
        case let .permissionRequested(payload):
            try container.encode(EventType.permissionRequested, forKey: .type)
            try container.encode(payload, forKey: .permissionRequested)
        case let .questionAsked(payload):
            try container.encode(EventType.questionAsked, forKey: .type)
            try container.encode(payload, forKey: .questionAsked)
        case let .sessionCompleted(payload):
            try container.encode(EventType.sessionCompleted, forKey: .type)
            try container.encode(payload, forKey: .sessionCompleted)
        case let .jumpTargetUpdated(payload):
            try container.encode(EventType.jumpTargetUpdated, forKey: .type)
            try container.encode(payload, forKey: .jumpTargetUpdated)
        case let .sessionMetadataUpdated(payload):
            try container.encode(EventType.sessionMetadataUpdated, forKey: .type)
            try container.encode(payload, forKey: .sessionMetadataUpdated)
        case let .actionableStateResolved(payload):
            try container.encode(EventType.actionableStateResolved, forKey: .type)
            try container.encode(payload, forKey: .actionableStateResolved)
        }
    }
}
