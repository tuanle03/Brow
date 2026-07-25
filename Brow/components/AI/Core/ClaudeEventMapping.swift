import Foundation

/// Bridges Brow's existing Claude Code hook decode layer
/// (`ClaudeCodeEvent.swift`) into the `AgentEvent`s the pure `SessionState`
/// reducer (Task 1.5) consumes. This is the adapter boundary: unlike the
/// reducer, it may read the wall clock, but it does no I/O and has no side
/// effects — the store's queueing/continuation/toast logic (Task 1.7) stays
/// in `ClaudeCodeStore`.
///
/// Brow's actual `ClaudeCodeEvent` cases (`sessionStart`, `sessionEnd`,
/// `userPromptSubmit`, `permissionRequest`, `notification`, `stop`,
/// `unknown`) are narrower than the generic PreToolUse/PostToolUse/
/// AskUserQuestion hook set the task template describes — Brow's hook
/// script only posts those seven, and `AskUserQuestion` arrives as a
/// `PermissionRequest` whose `tool_name == "AskUserQuestion"` (see
/// `ClaudeCodeStore.handlePermissionRequest`), not as its own hook. The
/// mapping below follows Brow's *actual* wire shape rather than the
/// template's generic one.
enum ClaudeEventMapping {
    /// Maps one decoded Claude Code hook event to zero or more `AgentEvent`s.
    /// Returns `[]` for hook events with no `AgentEvent` equivalent
    /// (`notification`, `unknown`) — Brow currently only surfaces those as
    /// ephemeral toasts, which have no session-state representation.
    static func mapClaudeEvent(
        _ payload: ClaudeCodeIncomingEvent,
        context: AgentBridgeEnvelope.HookRuntimeContextDTO?
    ) -> [AgentEvent] {
        let timestamp = payload.receivedAt

        switch payload.event {
        case .sessionStart(let p):
            guard let sessionID = p.sessionID else { return [] }
            let cwd = p.projectDirectory ?? p.cwd
            let started = SessionStarted(
                sessionID: sessionID,
                title: sessionTitle(cwd: cwd),
                tool: .claudeCode,
                origin: .live,
                initialPhase: .running,
                summary: sessionStartSummary(source: p.source),
                timestamp: timestamp,
                jumpTarget: buildJumpTarget(context: context, cwd: cwd)
            )
            return [.sessionStarted(started)]

        case .sessionEnd(let p):
            guard let sessionID = p.sessionID else { return [] }
            let reasonSuffix = p.reason.map { " (\($0))" } ?? ""
            let completed = SessionCompleted(
                sessionID: sessionID,
                summary: "Session ended\(reasonSuffix).",
                timestamp: timestamp,
                isSessionEnd: true
            )
            return [.sessionCompleted(completed)]

        case .userPromptSubmit(let p):
            guard let sessionID = p.sessionID else { return [] }
            let trimmed = p.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let activity = SessionActivityUpdated(
                sessionID: sessionID,
                summary: "You: \(short(trimmed, max: 80))",
                phase: .running,
                timestamp: timestamp,
                title: titleFromCwd(p.cwd)
            )
            return [.activityUpdated(activity)]

        case .permissionRequest(let p):
            guard let sessionID = p.sessionID else { return [] }
            // AskUserQuestion rides in on a PermissionRequest in Brow's hook
            // shape (see the enum doc comment above) — route it to
            // `questionAsked` instead of `permissionRequested`.
            if p.toolName == "AskUserQuestion",
               let prompt = buildQuestionPrompt(toolInput: p.toolInput, toolUseID: p.toolUseID) {
                let asked = QuestionAsked(sessionID: sessionID, prompt: prompt, timestamp: timestamp)
                return [.questionAsked(asked)]
            }
            let requested = PermissionRequested(
                sessionID: sessionID,
                request: buildPermissionRequest(p),
                timestamp: timestamp,
                title: titleFromCwd(p.projectDirectory ?? p.cwd)
            )
            return [.permissionRequested(requested)]

        case .notification:
            // No AgentEvent equivalent — Brow drops these as a toast-only
            // signal (see `ClaudeCodeStore.recordNotification`); they're
            // almost always a duplicate pre-ping of a PermissionRequest.
            return []

        case .stop(let p):
            guard let sessionID = p.sessionID else { return [] }
            let completed = SessionCompleted(
                sessionID: sessionID,
                summary: "Claude finished responding.",
                timestamp: timestamp
            )
            return [.sessionCompleted(completed)]

        case .unknown:
            return []
        }
    }

    // MARK: - SessionStart helpers

    private static func sessionTitle(cwd: String?) -> String {
        guard let cwd, !cwd.isEmpty else { return SessionState.genericFallbackTitle }
        let base = (cwd as NSString).lastPathComponent
        return base.isEmpty ? SessionState.genericFallbackTitle : base
    }

    /// Project title for the reducer's mid-flight backfill: the derived
    /// project name, or `nil` when `cwd` yields only the generic fallback (so
    /// the backfill has nothing better to adopt and leaves the title alone).
    private static func titleFromCwd(_ cwd: String?) -> String? {
        let derived = sessionTitle(cwd: cwd)
        return derived == SessionState.genericFallbackTitle ? nil : derived
    }

    private static func sessionStartSummary(source: String?) -> String {
        switch source {
        case "resume":  return "Session resumed."
        case "clear":   return "Session cleared."
        case "compact": return "Session compacted."
        default:        return "Session started."
        }
    }

    private static func buildJumpTarget(
        context: AgentBridgeEnvelope.HookRuntimeContextDTO?,
        cwd: String?
    ) -> JumpTarget? {
        guard let context, let terminalApp = context.terminalApp, !terminalApp.isEmpty else { return nil }
        let workingDirectory = context.cwd ?? cwd
        let name = sessionTitle(cwd: workingDirectory)
        return JumpTarget(
            terminalApp: terminalApp,
            workspaceName: name,
            paneTitle: name,
            workingDirectory: workingDirectory,
            terminalSessionID: context.terminalSessionID,
            terminalTTY: context.tty
        )
    }

    // MARK: - PermissionRequest

    private static func buildPermissionRequest(_ p: PermissionRequestPayload) -> PermissionRequest {
        let toolName = p.toolName
        let title = toolName == "ExitPlanMode" ? "Exit plan mode" : "Allow \(toolName)"
        let path = affectedPath(toolInput: p.toolInput, cwd: p.projectDirectory ?? p.cwd)
        let id = p.toolUseID ?? "\(p.sessionID ?? "unknown")-\(toolName)"
        return PermissionRequest(
            id: id,
            title: title,
            summary: permissionSummary(toolName: toolName, toolInput: p.toolInput),
            affectedPath: path,
            toolName: toolName,
            toolInput: p.toolInput,
            toolUseID: p.toolUseID,
            suggestedUpdates: (p.permissionSuggestions ?? []).compactMap(mapSuggestion)
        )
    }

    /// Ported from Open Island's `permissionRequestSummary`
    /// (ClaudeHooks.swift:913-933), trimmed to what Brow's
    /// `PermissionRequestPayload` actually carries (no `notificationPreview`
    /// — Brow's PermissionRequest hook body has no message field). Prefers a
    /// tool-specific activity description — duplicated in miniature from
    /// `ClaudeCodeStore.formatToolActivity` rather than calling it directly:
    /// that method lives on `@MainActor final class ClaudeCodeStore`, so
    /// calling it from this non-isolated pure mapper would force
    /// `mapClaudeEvent` onto the main actor too. Small, pure, worth
    /// duplicating rather than refactoring the store in this task.
    ///
    /// Unlisted tools fall through to a full sentence ("Claude Code wants
    /// to run NotebookEdit.") rather than `activityDescription`'s bare
    /// tool-name fallback — the two callers of `specificActivity` want
    /// different unmatched-tool fallbacks, so this calls the nil-returning
    /// core directly instead of going through `activityDescription`.
    private static func permissionSummary(toolName: String, toolInput: [String: AnyJSON]?) -> String {
        if toolName == "ExitPlanMode" {
            return "Claude wants to exit plan mode and start implementation."
        }
        if let activity = specificActivity(toolName: toolName, toolInput: toolInput ?? [:]) {
            return activity
        }
        return "\(AgentTool.claudeCode.displayName) wants to run \(toolName)."
    }

    /// The activity-chip flavor: falls back to the bare tool name for
    /// unmatched tools (matching `ClaudeCodeStore.formatToolActivity`).
    /// Not `private` (unlike its sibling `specificActivity`) so
    /// `ClaudeEventMappingTests` can assert this fallback directly —
    /// `permissionSummary`'s different fallback is covered indirectly via
    /// `mapClaudeEvent`, but there's no such public path to this one yet.
    static func activityDescription(toolName: String, toolInput: [String: AnyJSON]) -> String {
        specificActivity(toolName: toolName, toolInput: toolInput) ?? toolName
    }

    /// Miniature duplicate of `ClaudeCodeStore.formatToolActivity` — see the
    /// doc comment on `permissionSummary` for why this isn't a shared call.
    /// `nil` for unmatched tools; callers (`activityDescription`,
    /// `permissionSummary`) each pick their own fallback.
    private static func specificActivity(toolName: String, toolInput: [String: AnyJSON]) -> String? {
        func basename(_ path: String) -> String {
            let last = (path as NSString).lastPathComponent
            return last.isEmpty ? path : last
        }
        switch toolName {
        case "Bash":
            let cmd = toolInput["command"]?.asDisplayString ?? ""
            return cmd.isEmpty ? "Bash" : short(cmd, max: 64)
        case "Edit":
            return toolInput["file_path"].map { "Editing \(basename($0.asDisplayString))" } ?? "Editing"
        case "Write":
            return toolInput["file_path"].map { "Writing \(basename($0.asDisplayString))" } ?? "Writing"
        case "Read":
            return toolInput["file_path"].map { "Reading \(basename($0.asDisplayString))" } ?? "Reading"
        case "Grep":
            return toolInput["pattern"].map { "Searching \(short($0.asDisplayString, max: 32))" } ?? "Searching"
        case "Glob":
            return toolInput["pattern"].map { "Listing \(short($0.asDisplayString, max: 32))" } ?? "Listing"
        case "WebFetch":
            return toolInput["url"].map { "Fetching \(short($0.asDisplayString, max: 40))" } ?? "Fetching"
        case "WebSearch":
            return toolInput["query"].map { "Searching the web for \(short($0.asDisplayString, max: 36))" } ?? "Searching the web"
        case "TodoWrite":
            return "Updating todos"
        case "Task":
            return toolInput["description"].map { "Subagent: \(short($0.asDisplayString, max: 40))" } ?? "Running subagent"
        default:
            return nil
        }
    }

    private static func affectedPath(toolInput: [String: AnyJSON]?, cwd: String?) -> String {
        guard let toolInput else { return cwd ?? "" }
        for key in ["file_path", "path", "notebook_path", "target_file", "working_directory"] {
            if let value = toolInput[key]?.asDisplayString, !value.isEmpty { return value }
        }
        if let command = toolInput["command"]?.asDisplayString, !command.isEmpty { return command }
        return cwd ?? ""
    }

    private static func short(_ s: String, max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max - 1)) + "…"
    }

    /// Maps one of Claude Code's `permission_suggestions` entries
    /// (Brow's `PermissionSuggestion`, decoded from the hook's raw JSON)
    /// into the typed `ClaudePermissionUpdate` the approval UI/round-trip
    /// expects. Unrecognized `type`/`mode` values are dropped rather than
    /// guessed.
    private static func mapSuggestion(_ s: PermissionSuggestion) -> ClaudePermissionUpdate? {
        let destination = ClaudePermissionUpdateDestination(rawValue: s.destination ?? "session") ?? .session
        switch s.type {
        case "addRules":
            let rules = (s.rules ?? []).map {
                ClaudePermissionRuleValue(toolName: $0.toolName ?? "", ruleContent: $0.ruleContent)
            }
            let behavior = ClaudePermissionBehavior(rawValue: s.behavior ?? "allow") ?? .allow
            return .addRules(destination: destination, rules: rules, behavior: behavior)
        case "setMode":
            guard let mode = s.mode, let parsedMode = ClaudePermissionMode(rawValue: mode) else { return nil }
            return .setMode(destination: destination, mode: parsedMode)
        default:
            return nil
        }
    }

    // MARK: - AskUserQuestion → QuestionPrompt

    /// Ported from Open Island's `questionPrompt` (ClaudeHooks.swift:822-878),
    /// widened to also accept the simpler `{ question: "..." }` shape
    /// Brow's `ClaudeCodeStore.parseAskUserQuestion` already tolerated.
    /// Appends a synthetic freeform "Other" option per question, matching
    /// the reference (ClaudeHooks.swift:854-857) and Claude Code's own CLI
    /// behavior (the model is told not to add one; the client does).
    private static func buildQuestionPrompt(
        toolInput: [String: AnyJSON]?,
        toolUseID: String?
    ) -> QuestionPrompt? {
        guard let toolInput else { return nil }

        // Simple shape: top-level "question" string, no options.
        if case let .string(text)? = toolInput["question"], !text.isEmpty {
            let item = QuestionPromptItem(
                question: text,
                header: text,
                options: [QuestionOption(label: "Other", description: "", allowsFreeform: true)]
            )
            return QuestionPrompt(title: text, questions: [item], toolUseID: toolUseID)
        }

        // Structured shape: questions: [{ question, header, options, multiSelect }]
        guard case let .array(rawQuestions)? = toolInput["questions"] else { return nil }

        let items: [QuestionPromptItem] = rawQuestions.compactMap { raw in
            guard case let .object(q) = raw,
                  case let .string(questionText)? = q["question"], !questionText.isEmpty
            else { return nil }

            let header: String
            if case let .string(h)? = q["header"] { header = h } else { header = questionText }

            var options: [QuestionOption] = []
            if case let .array(rawOptions)? = q["options"] {
                for rawOption in rawOptions {
                    guard case let .object(o) = rawOption,
                          case let .string(label)? = o["label"], !label.isEmpty
                    else { continue }
                    var description = ""
                    if case let .string(d)? = o["description"] { description = d }
                    options.append(QuestionOption(label: label, description: description))
                }
            }
            guard !options.isEmpty else { return nil }
            options.append(QuestionOption(label: "Other", description: "", allowsFreeform: true))

            var multiSelect = false
            if case let .bool(m)? = q["multiSelect"] { multiSelect = m }

            return QuestionPromptItem(question: questionText, header: header, options: options, multiSelect: multiSelect)
        }

        guard !items.isEmpty else { return nil }
        let title = items.count == 1 ? items[0].question : "Claude has \(items.count) questions for you."
        return QuestionPrompt(title: title, questions: items, toolUseID: toolUseID)
    }
}
