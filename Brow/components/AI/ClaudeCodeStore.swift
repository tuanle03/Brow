import Foundation
import Combine
import AppKit
import SwiftUI

/// Single source of truth for the AI Sessions feature once #3 lands:
/// - Holds the FIFO queue of `PreToolUse` calls waiting on a human decision.
/// - Tracks active sessions so the (future) expanded notch tab can list them.
/// - Persists "always allow" rules to `~/.brow/rules.json` so a tool the
///   user has trusted once never re-prompts.
///
/// The bridge calls `handlePermissionRequest(_:rawJSON:)` and awaits the resulting
/// `ApprovalDecision`. The UI (debug panel for now; real sneak peek in
/// later PRs) calls `decide(_:as:)` to resolve the pending entry the user
/// picked. A timeout on the bridge side guarantees we don't keep Claude
/// Code's hook script hanging if the user walks away.
@MainActor
final class ClaudeCodeStore: ObservableObject {
    static let shared = ClaudeCodeStore()

    @Published private(set) var pending: [PendingApproval] = []
    /// Resolved permission requests, newest first. Includes both
    /// user-decided and auto-timed-out approvals so the user can scroll
    /// back through prompts they may have missed. Capped to keep memory
    /// bounded.
    @Published private(set) var recentlyResolved: [ResolvedApproval] = []
    @Published private(set) var sessions: [String: SessionState] = [:]
    @Published private(set) var rules: [PermissionRule] = []
    @Published private(set) var lastRuleError: String?
    /// Transient Claude Code `Notification` payload — set when one arrives,
    /// cleared after a few seconds. Drives the small toast that pops out of
    /// the notch when Claude needs the user's attention.
    @Published private(set) var transientNotification: TransientNotification?

    private static let recentlyResolvedCap = 30

    /// True while Claude Code has *something* the user should see right now —
    /// either a pending approval or a transient notification toast. ContentView
    /// observes this and drives the notch expand / collapse animation.
    var shouldAutoExpand: Bool {
        !pending.isEmpty || transientNotification != nil
    }

    /// Per-pending continuation, keyed by `PendingApproval.id`. Resolved
    /// exactly once — either by the user via `decide`, or by the bridge's
    /// timeout via `resolveTimeout`.
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]
    private var notificationDismissTask: Task<Void, Never>?

    private init() {
        rules = (try? PermissionRule.loadAll()) ?? []
    }

    // MARK: - Bridge entry point

    /// Returns the decision to send back to Claude Code. If a saved rule
    /// matches, returns immediately. Otherwise enqueues the request and
    /// suspends until the user decides (or the bridge times us out).
    func handlePermissionRequest(_ payload: PermissionRequestPayload, rawJSON: String) async -> String {
        updateSession(from: payload)

        let approval = PendingApproval(
            id: UUID(),
            receivedAt: Date(),
            sessionID: payload.sessionID,
            toolName: payload.toolName,
            toolInput: payload.toolInput ?? [:],
            projectDirectory: payload.projectDirectory ?? payload.cwd,
            suggestions: payload.permissionSuggestions ?? [],
            rawJSON: rawJSON
        )

        if let matched = matchRule(for: payload) {
            return matched.hookOutputJSON(for: approval)
        }

        // AskUserQuestion is Claude's built-in multi-choice prompt: it
        // renders its own interactive picker in the terminal and reads
        // the user's answer from there. The permission hook can only
        // return allow/deny, so a notch "Allow / Deny" bubble would be
        // misleading and useless — auto-allow and instead surface the
        // question as a transient notification so the user knows to
        // switch to Claude Code to answer.
        if payload.toolName == "AskUserQuestion" {
            // The hook contract only round-trips allow/deny — Claude
            // Code's tool reads the user's actual answer from stdin in
            // the terminal. Auto-allow so we don't block it; the toast
            // we surface lets the user know what to type back.
            let decision: ApprovalDecision = .allow
            archive(approval, outcome: .decided(decision))
            let question = Self.parseAskUserQuestion(from: payload.toolInput ?? [:])
            let body = question.map { "Claude is asking: \($0.text)" }
                ?? "Claude is asking a question — answer in Claude Code."
            surfaceToast(.notification(body),
                         sessionID: payload.sessionID,
                         projectDirectory: payload.projectDirectory,
                         question: question)
            return decision.hookOutputJSON(for: approval)
        }

        let decision = await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
            continuations[approval.id] = cont
            pending.append(approval)
            // Auto-fall back to .ask if the user hasn't decided in time.
            // Claude Code's hook script gives us 60s before its curl errors
            // out; bail at 55s so the response always makes it back.
            let id = approval.id
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(55))
                await MainActor.run { self?.resolveTimeout(for: id) }
            }
        }
        return decision.hookOutputJSON(for: approval)
    }

    /// Called from the bridge when the hook script has been waiting too long.
    /// Resolves the head of the queue with `.ask` (Claude Code falls back to
    /// its native prompt) so we never block the script past its own timeout.
    func resolveTimeout(for id: UUID) {
        guard let cont = continuations.removeValue(forKey: id) else { return }
        if let approval = pending.first(where: { $0.id == id }) {
            archive(approval, outcome: .timedOut)
        }
        pending.removeAll { $0.id == id }
        cont.resume(returning: .ask)
    }

    // MARK: - User-driven decisions

    /// Called by the UI / debug buttons. Resolves the matching pending entry
    /// and persists a local rule if `as == .allowAlways`. `.allowWith(s)`
    /// hands Claude Code the suggestion so *it* records the rule on its side,
    /// no Brow-local mirror needed.
    func decide(_ id: UUID, as decision: ApprovalDecision) {
        guard let approval = pending.first(where: { $0.id == id }),
              let cont = continuations.removeValue(forKey: id)
        else { return }
        pending.removeAll { $0.id == id }

        if decision == .allowAlways {
            persistAllowRule(for: approval)
        }
        archive(approval, outcome: .decided(decision))
        cont.resume(returning: decision)
    }

    private func archive(_ approval: PendingApproval, outcome: ResolvedApproval.Outcome) {
        let resolved = ResolvedApproval(
            approval: approval,
            outcome: outcome,
            resolvedAt: Date()
        )
        recentlyResolved.insert(resolved, at: 0)
        if recentlyResolved.count > Self.recentlyResolvedCap {
            recentlyResolved.removeLast(recentlyResolved.count - Self.recentlyResolvedCap)
        }
    }

    func clearRecentlyResolved() {
        recentlyResolved.removeAll()
    }

    /// Convenience for the head-of-queue case (current sneak peek surface).
    func decideHead(as decision: ApprovalDecision) {
        guard let head = pending.first else { return }
        decide(head.id, as: decision)
    }

    // MARK: - Rule persistence

    /// Persist an "always allow" rule based on the resolved approval. For PR
    /// #3 we use a coarse rule (tool-name match, no argument matcher). Later
    /// PRs add a UI to tune that — for now editing `~/.brow/rules.json`
    /// directly is the escape hatch.
    private func persistAllowRule(for approval: PendingApproval) {
        let rule = PermissionRule(
            toolName: approval.toolName,
            argMatcher: nil,
            decision: .allow
        )
        // Replace any existing rule for the same tool/matcher pair.
        rules.removeAll { $0.toolName == rule.toolName && $0.argMatcher == rule.argMatcher }
        rules.append(rule)
        do {
            try PermissionRule.saveAll(rules)
            lastRuleError = nil
        } catch {
            lastRuleError = error.localizedDescription
        }
    }

    func removeRule(_ rule: PermissionRule) {
        rules.removeAll { $0 == rule }
        try? PermissionRule.saveAll(rules)
    }

    private func matchRule(for payload: PermissionRequestPayload) -> ApprovalDecision? {
        for rule in rules where rule.matches(payload) {
            switch rule.decision {
            case .allow:    return .allow
            case .deny:     return .deny
            }
        }
        return nil
    }

    // MARK: - Sessions

    private func updateSession(from payload: PermissionRequestPayload) {
        guard let id = payload.sessionID else { return }
        let now = Date()
        if var existing = sessions[id] {
            existing.lastEventAt = now
            existing.lastTool = payload.toolName
            existing.projectDirectory = payload.projectDirectory ?? existing.projectDirectory
            sessions[id] = existing
        } else {
            sessions[id] = SessionState(
                id: id,
                firstSeenAt: now,
                lastEventAt: now,
                lastTool: payload.toolName,
                projectDirectory: payload.projectDirectory ?? payload.cwd,
                lastUserPrompt: nil,
                terminalAppHint: captureTerminalAppHint()
            )
        }
    }

    func recordSessionStart(_ payload: SessionStartPayload) {
        // Capture the terminal app the user is looking at right now —
        // best-effort signal for "where was Claude Code launched from".
        // touchSession only fills hint when creating, never overwrites.
        touchSession(
            id: payload.sessionID,
            projectDirectory: payload.projectDirectory ?? payload.cwd,
            terminalAppHint: captureTerminalAppHint()
        )
    }

    func recordSessionEnd(_ payload: SessionEndPayload) {
        guard let id = payload.sessionID else { return }
        sessions.removeValue(forKey: id)
    }

    /// Stores the latest user prompt against the session, so the Monitor row
    /// can render "You: <prompt>" as the task description. Only the most
    /// recent prompt is kept — the task list mirrors "what is Claude
    /// currently working on" not "what was historically asked".
    func recordUserPrompt(_ payload: UserPromptSubmitPayload) {
        guard let id = payload.sessionID else { return }
        let trimmed = payload.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let now = Date()
        if var existing = sessions[id] {
            existing.lastEventAt = now
            existing.lastUserPrompt = trimmed
            sessions[id] = existing
        } else {
            sessions[id] = SessionState(
                id: id,
                firstSeenAt: now,
                lastEventAt: now,
                lastTool: nil,
                projectDirectory: payload.cwd,
                lastUserPrompt: trimmed,
                terminalAppHint: captureTerminalAppHint()
            )
        }
    }

    func recordNotification(_ payload: NotificationPayload) {
        touchSession(id: payload.sessionID, projectDirectory: payload.projectDirectory)
        surfaceToast(.notification(payload.message),
                     sessionID: payload.sessionID,
                     projectDirectory: payload.projectDirectory)
    }

    func recordStop(_ payload: StopPayload) {
        touchSession(id: payload.sessionID, projectDirectory: payload.projectDirectory ?? payload.cwd)
        surfaceToast(.stopped,
                     sessionID: payload.sessionID,
                     projectDirectory: payload.projectDirectory ?? payload.cwd)
    }

    func dismissTransientNotification() {
        notificationDismissTask?.cancel()
        transientNotification = nil
    }

    /// Public side-door for non-hook callers (currently `TerminalJumpService`)
    /// to drop a transient toast on the panel — e.g. "iTerm2 not running"
    /// when a jump fails. Reuses the existing 5s auto-dismiss machinery.
    func surfaceLocalNotice(_ message: String, sessionID: String? = nil) {
        surfaceToast(.notification(message),
                     sessionID: sessionID,
                     projectDirectory: nil)
    }

    private func touchSession(id: String?,
                              projectDirectory: String?,
                              terminalAppHint: String? = nil) {
        guard let id else { return }
        let now = Date()
        if var existing = sessions[id] {
            existing.lastEventAt = now
            // Don't overwrite a hint once captured — the first sighting
            // (at SessionStart) is the most reliable.
            if existing.terminalAppHint == nil, let hint = terminalAppHint {
                existing.terminalAppHint = hint
            }
            sessions[id] = existing
        } else {
            sessions[id] = SessionState(
                id: id,
                firstSeenAt: now,
                lastEventAt: now,
                lastTool: nil,
                projectDirectory: projectDirectory,
                lastUserPrompt: nil,
                terminalAppHint: terminalAppHint
            )
        }
    }

    /// Best-effort: return the foreground app's display name unless it's
    /// Brow itself (e.g. user clicked the notch, then triggered a hook
    /// indirectly — rare but possible). Used only as a UI hint; nothing
    /// is round-tripped back to Claude Code.
    private func captureTerminalAppHint() -> String? {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier { return nil }
        return app.localizedName
    }

    private func surfaceToast(_ kind: TransientNotification.Kind,
                              sessionID: String?,
                              projectDirectory: String?,
                              question: AIQuestion? = nil,
                              autoDismissAfter seconds: TimeInterval = 5) {
        transientNotification = TransientNotification(
            id: UUID(),
            receivedAt: Date(),
            sessionID: sessionID,
            kind: kind,
            projectDirectory: projectDirectory,
            question: question
        )
        notificationDismissTask?.cancel()
        // AskUserQuestion toasts hang around longer than plain toasts —
        // the user is probably switching to the terminal to answer.
        let duration = question == nil ? seconds : max(seconds, 30)
        notificationDismissTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            await MainActor.run {
                guard let self else { return }
                if !Task.isCancelled { self.transientNotification = nil }
            }
        }
    }

    /// Decodes Claude Code's `AskUserQuestion` payload into a structured
    /// `AIQuestion`. Supports both the simple `{ question: "..." }`
    /// shape and the richer `{ questions: [{ question, options }] }`
    /// shape — we pick the *first* sub-question of the latter, which is
    /// what the CLI itself does. Each option is given a `K<n>` shortcut
    /// label so the UI can render keyboard hints.
    private static func parseAskUserQuestion(from toolInput: [String: AnyJSON]) -> AIQuestion? {
        // Shape 1: top-level question string, no options.
        if case let .string(s)? = toolInput["question"], !s.isEmpty {
            return AIQuestion(text: s, options: [])
        }
        // Shape 2: structured `questions: [{ question, options: [...] }]`.
        guard case let .array(arr)? = toolInput["questions"],
              case let .object(first)? = arr.first,
              case let .string(text)? = first["question"],
              !text.isEmpty
        else { return nil }

        var options: [AIQuestion.Option] = []
        if case let .array(rawOptions)? = first["options"] {
            for (index, raw) in rawOptions.enumerated() {
                let label: String?
                switch raw {
                case .string(let s):
                    label = s
                case .object(let obj):
                    // Some agents wrap each option in `{ label: "..." }`.
                    if case let .string(s)? = obj["label"] { label = s }
                    else if case let .string(s)? = obj["text"] { label = s }
                    else { label = nil }
                default:
                    label = nil
                }
                guard let label, !label.isEmpty else { continue }
                options.append(.init(id: "K\(index + 1)", label: label))
            }
        }
        return AIQuestion(text: text, options: options)
    }
}

// MARK: - Models

struct ResolvedApproval: Identifiable, Equatable {
    enum Outcome: Equatable {
        case decided(ApprovalDecision)
        /// Brow's user-decision timer fired (~55s) before the user touched
        /// anything; Claude Code fell back to its native dialog.
        case timedOut
    }

    var id: UUID { approval.id }
    let approval: PendingApproval
    let outcome: Outcome
    let resolvedAt: Date

    var statusLabel: String {
        switch outcome {
        case .decided(.allow):                       return "Allowed"
        case .decided(.allowAlways):                 return "Allowed (always)"
        case .decided(.allowWith(let suggestion)):   return suggestion.displayLabel
        case .decided(.deny):                        return "Denied"
        case .decided(.ask):                         return "Deferred to CLI"
        case .timedOut:                              return "Timed out"
        }
    }

    var statusTint: Color {
        switch outcome {
        case .decided(.allow), .decided(.allowAlways), .decided(.allowWith): return .green
        case .decided(.deny):     return .red
        case .decided(.ask):      return .secondary
        case .timedOut:           return .orange
        }
    }
}

struct TransientNotification: Identifiable, Equatable {
    enum Kind: Equatable {
        /// Claude Code emitted a Notification event with a message string.
        case notification(String)
        /// Claude finished responding and is now waiting for the next prompt.
        case stopped
    }

    let id: UUID
    let receivedAt: Date
    let sessionID: String?
    let kind: Kind
    let projectDirectory: String?
    /// Populated when the toast is sourced from `AskUserQuestion`. The
    /// panel uses presence of this field to switch into the Ask section
    /// and render options instead of plain body text.
    let question: AIQuestion?

    var title: String {
        switch kind {
        case .notification: return "Claude"
        case .stopped:      return "Claude is done"
        }
    }

    var body: String {
        switch kind {
        case .notification(let message): return message
        case .stopped:                   return projectDirectory.map { ($0 as NSString).lastPathComponent } ?? "Ready for your next prompt"
        }
    }
}

struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let receivedAt: Date
    let sessionID: String?
    let toolName: String
    let toolInput: [String: AnyJSON]
    let projectDirectory: String?
    /// Claude Code's per-request suggestions — one row per "Yes, allow X" /
    /// "Switch to acceptEdits" entry. Empty means the CLI is offering the
    /// minimal 2-option Yes/No prompt.
    let suggestions: [PermissionSuggestion]
    let rawJSON: String

    /// Best-effort one-line summary of the call (e.g. the bash command, the
    /// file path being edited). Used by the debug Settings panel + future
    /// sneak peek.
    var targetDescription: String {
        if let command = toolInput["command"]?.asDisplayString {
            return command
        }
        if let filePath = toolInput["file_path"]?.asDisplayString {
            return filePath
        }
        if let path = toolInput["path"]?.asDisplayString {
            return path
        }
        return toolInput.keys.sorted().joined(separator: ", ")
    }
}

struct SessionState: Identifiable, Equatable {
    let id: String
    var firstSeenAt: Date
    var lastEventAt: Date
    var lastTool: String?
    var projectDirectory: String?
    /// Most recent user prompt submitted in this session. Populated by the
    /// `UserPromptSubmit` hook. Drives the "You: …" subtitle in the Monitor
    /// row so the panel reads like a TODO list of asks.
    var lastUserPrompt: String?
    /// Best-effort name of the terminal app the session was launched from
    /// (e.g. "iTerm2", "Ghostty"). Captured at SessionStart by sampling
    /// `NSWorkspace.frontmostApplication` — the hook payload doesn't
    /// include this so we infer it from whatever app the user was looking
    /// at when Claude Code printed its first banner. nil when we couldn't
    /// determine the app or Brow itself was foreground.
    var terminalAppHint: String?
}

enum ApprovalDecision: Equatable {
    case allow
    /// Allow + apply *all* of Claude Code's suggestions (legacy "Always
    /// Allow" path — Brow saves a local rule too so future calls bypass
    /// the prompt entirely).
    case allowAlways
    /// Allow + apply exactly one of Claude Code's suggestions, e.g. "Always
    /// allow Bash in /project/" or "Switch to acceptEdits".
    case allowWith(PermissionSuggestion)
    case deny
    /// "Defer to Claude Code's native UI" — the bridge returns an empty
    /// `hookSpecificOutput` so the CLI shows its own prompt. Used when the
    /// store's user-decision timeout fires before the user picked anything.
    case ask

    /// Hook response body. `PermissionRequest` uses
    /// `hookSpecificOutput.decision.{behavior, updatedPermissions}`. `.ask`
    /// returns an empty body so Claude Code falls back to its native dialog.
    func hookOutputJSON(for approval: PendingApproval) -> String {
        switch self {
        case .allow:
            return Self.responseJSON(decision: ["behavior": "allow"])
        case .allowAlways:
            var d: [String: Any] = ["behavior": "allow"]
            if !approval.suggestions.isEmpty {
                d["updatedPermissions"] = approval.suggestions.map(\.asResponseDict)
            }
            return Self.responseJSON(decision: d)
        case .allowWith(let suggestion):
            return Self.responseJSON(decision: [
                "behavior": "allow",
                "updatedPermissions": [suggestion.asResponseDict],
            ])
        case .deny:
            return Self.responseJSON(decision: ["behavior": "deny"])
        case .ask:
            return "{}"
        }
    }

    private static func responseJSON(decision: [String: Any]) -> String {
        let envelope: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision,
            ]
        ]
        if let data = try? JSONSerialization.data(withJSONObject: envelope,
                                                  options: [.withoutEscapingSlashes]),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return #"{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"deny"}}}"#
    }
}

// MARK: - Rules file

struct PermissionRule: Codable, Equatable, Identifiable {
    var id: String { "\(toolName)|\(argMatcher ?? "*")" }

    let toolName: String
    /// Optional matcher against `tool_input.command` (Bash) or
    /// `tool_input.file_path` / `tool_input.path` (Edit / Write / Read).
    /// nil = match any args. Pattern is a substring match for PR #3.
    let argMatcher: String?
    let decision: Decision

    enum Decision: String, Codable {
        case allow
        case deny
    }

    func matches(_ payload: PermissionRequestPayload) -> Bool {
        guard toolName == payload.toolName else { return false }
        guard let matcher = argMatcher, !matcher.isEmpty else { return true }
        let target = payload.toolInput?["command"]?.asDisplayString
            ?? payload.toolInput?["file_path"]?.asDisplayString
            ?? payload.toolInput?["path"]?.asDisplayString
            ?? ""
        return target.contains(matcher)
    }

    static var rulesPath: String {
        (ClaudeCodeHookInstaller.realHomeDirectory as NSString).appendingPathComponent(".brow/rules.json")
    }

    private struct Envelope: Codable {
        let version: Int
        let rules: [PermissionRule]
    }

    static func loadAll() throws -> [PermissionRule] {
        let path = rulesPath
        let fm = FileManager.default
        guard fm.fileExists(atPath: path) else { return [] }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard !data.isEmpty else { return [] }
        let env = try JSONDecoder().decode(Envelope.self, from: data)
        return env.rules
    }

    static func saveAll(_ rules: [PermissionRule]) throws {
        let url = URL(fileURLWithPath: rulesPath)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let env = Envelope(version: 1, rules: rules)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(env)
        try data.write(to: url, options: [.atomic])
    }
}
