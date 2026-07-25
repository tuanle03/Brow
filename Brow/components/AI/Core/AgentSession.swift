import Foundation

// MARK: - SessionOrigin

/// Where a session's data came from. `.demo` sessions are synthetic rows
/// used for onboarding/preview UI and are always shown regardless of
/// process/hook liveness (see `AgentSession.isVisibleInIsland`).
enum SessionOrigin: String, Codable, Sendable, Equatable {
    case live
    case demo
}

// MARK: - Metadata (Claude + Codex only — Core scope)

/// Claude Code-specific session metadata. Trimmed from the Open Island
/// reference's `ClaudeSessionMetadata`: dropped `startupSource`,
/// `permissionMode`, `agentID`, `agentType`, `worktreeBranch`,
/// `activeSubagents`, `activeTasks` — those hang off types
/// (`ClaudeSessionStartSource`, `ClaudeSubagentInfo`, `ClaudeTaskInfo`) not
/// yet ported to Brow and unused by `isVisibleInIsland`. Add them back
/// field-for-field when a later task's bridge/reducer actually needs them.
struct ClaudeSessionMetadata: Codable, Sendable, Equatable {
    var transcriptPath: String?
    var initialUserPrompt: String?
    var lastUserPrompt: String?
    var lastAssistantMessage: String?
    var currentTool: String?
    var currentToolInputPreview: String?
    var model: String?

    init(
        transcriptPath: String? = nil,
        initialUserPrompt: String? = nil,
        lastUserPrompt: String? = nil,
        lastAssistantMessage: String? = nil,
        currentTool: String? = nil,
        currentToolInputPreview: String? = nil,
        model: String? = nil
    ) {
        self.transcriptPath = transcriptPath
        self.initialUserPrompt = initialUserPrompt
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.currentTool = currentTool
        self.currentToolInputPreview = currentToolInputPreview
        self.model = model
    }
}

/// Codex-specific session metadata. Ported field-for-field from the
/// reference's `CodexSessionMetadata` — it's small and self-contained
/// (all `String?`, no entangled types), so nothing was trimmed.
struct CodexSessionMetadata: Codable, Sendable, Equatable {
    var transcriptPath: String?
    var initialUserPrompt: String?
    var lastUserPrompt: String?
    var lastAssistantMessage: String?
    var currentTool: String?
    var currentCommandPreview: String?

    init(
        transcriptPath: String? = nil,
        initialUserPrompt: String? = nil,
        lastUserPrompt: String? = nil,
        lastAssistantMessage: String? = nil,
        currentTool: String? = nil,
        currentCommandPreview: String? = nil
    ) {
        self.transcriptPath = transcriptPath
        self.initialUserPrompt = initialUserPrompt
        self.lastUserPrompt = lastUserPrompt
        self.lastAssistantMessage = lastAssistantMessage
        self.currentTool = currentTool
        self.currentCommandPreview = currentCommandPreview
    }
}

// MARK: - AgentSession

/// The canonical per-session record the reducer (`SessionState`, task 1.5)
/// stores keyed by `id`. Ported field-for-field from Open Island's
/// `AgentSession`, restricted to Brow's Claude+Codex Core scope: gemini/
/// openCode/cursor metadata fields and `isCodexAppSession` (Brow doesn't
/// track a Codex desktop-app distinction — `AgentTool` here is CLI-only)
/// were dropped.
struct AgentSession: Identifiable, Codable, Equatable, Sendable {
    var id: String
    var title: String
    var tool: AgentTool
    var origin: SessionOrigin?
    var attachmentState: SessionAttachmentState
    var phase: SessionPhase
    var summary: String
    var updatedAt: Date
    /// First time this session appeared in local state. Written once and
    /// persisted so the closed-island's right-slot grid can keep a stable
    /// display order regardless of how the panel list is sorted.
    var firstSeenAt: Date
    var permissionRequest: PermissionRequest?
    var questionPrompt: QuestionPrompt?
    var jumpTarget: JumpTarget?
    var claudeMetadata: ClaudeSessionMetadata?
    var codexMetadata: CodexSessionMetadata?

    /// Whether this session originates from a remote (SSH) connection.
    var isRemote: Bool

    /// Whether this session's lifecycle is driven by hook events rather than
    /// process polling. When `true`, visibility is determined by hook
    /// signals (`SessionStart` / `SessionEnd`) instead of `ps`/`lsof`
    /// process discovery.
    var isHookManaged: Bool

    /// Whether the agent session has ended (received `SessionEnd` hook).
    /// Only meaningful for hook-managed sessions.
    var isSessionEnded: Bool

    /// Whether the agent process is currently alive according to process
    /// discovery. Used for non-hook-managed sessions (e.g. Codex, synthetic
    /// Claude sessions).
    var isProcessAlive: Bool

    /// Number of consecutive reconciliation polls where the process was not
    /// found. Reset to 0 when the process is found. When >= 2 (~6 seconds),
    /// the session is considered gone. Prevents flicker from momentary `ps`
    /// gaps.
    var processNotSeenCount: Int

    init(
        id: String,
        title: String = "",
        tool: AgentTool,
        origin: SessionOrigin? = nil,
        attachmentState: SessionAttachmentState = .stale,
        phase: SessionPhase = .running,
        summary: String = "",
        updatedAt: Date = Date(),
        firstSeenAt: Date? = nil,
        permissionRequest: PermissionRequest? = nil,
        questionPrompt: QuestionPrompt? = nil,
        jumpTarget: JumpTarget? = nil,
        claudeMetadata: ClaudeSessionMetadata? = nil,
        codexMetadata: CodexSessionMetadata? = nil,
        isRemote: Bool = false,
        isHookManaged: Bool = false,
        isSessionEnded: Bool = false,
        isProcessAlive: Bool = false,
        processNotSeenCount: Int = 0
    ) {
        self.id = id
        self.title = title
        self.tool = tool
        self.origin = origin
        self.attachmentState = attachmentState
        self.phase = phase
        self.summary = summary
        self.updatedAt = updatedAt
        self.firstSeenAt = firstSeenAt ?? updatedAt
        self.permissionRequest = permissionRequest
        self.questionPrompt = questionPrompt
        self.jumpTarget = jumpTarget
        self.claudeMetadata = claudeMetadata
        self.codexMetadata = codexMetadata
        self.isRemote = isRemote
        self.isHookManaged = isHookManaged
        self.isSessionEnded = isSessionEnded
        self.isProcessAlive = isProcessAlive
        self.processNotSeenCount = processNotSeenCount
    }
}

extension AgentSession {
    /// Visibility rule for the island UI, ported verbatim from the
    /// reference (minus the Codex.app branch — not applicable, see the
    /// type doc comment above): demo sessions are always visible; a phase
    /// requiring attention is always visible; hook-managed sessions stay
    /// visible until they've ended; everything else is visible only while
    /// its process is alive.
    var isVisibleInIsland: Bool {
        if origin == .demo { return true }
        if phase.requiresAttention { return true }
        if isHookManaged { return !isSessionEnded }
        return isProcessAlive
    }
}
