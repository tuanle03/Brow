import Foundation
import Combine
import AppKit

/// Single source of truth for the AI Sessions feature once #3 lands:
/// - Holds the FIFO queue of `PreToolUse` calls waiting on a human decision.
/// - Tracks active sessions so the (future) expanded notch tab can list them.
/// - Persists "always allow" rules to `~/.brow/rules.json` so a tool the
///   user has trusted once never re-prompts.
///
/// The bridge calls `handlePreToolUse(_:rawJSON:)` and awaits the resulting
/// `ApprovalDecision`. The UI (debug panel for now; real sneak peek in
/// later PRs) calls `decide(_:as:)` to resolve the pending entry the user
/// picked. A timeout on the bridge side guarantees we don't keep Claude
/// Code's hook script hanging if the user walks away.
@MainActor
final class ClaudeCodeStore: ObservableObject {
    static let shared = ClaudeCodeStore()

    @Published private(set) var pending: [PendingApproval] = []
    @Published private(set) var sessions: [String: SessionState] = [:]
    @Published private(set) var rules: [PermissionRule] = []
    @Published private(set) var lastRuleError: String?

    /// Per-pending continuation, keyed by `PendingApproval.id`. Resolved
    /// exactly once — either by the user via `decide`, or by the bridge's
    /// timeout via `resolveTimeout`.
    private var continuations: [UUID: CheckedContinuation<ApprovalDecision, Never>] = [:]

    private init() {
        rules = (try? PermissionRule.loadAll()) ?? []
    }

    // MARK: - Bridge entry point

    /// Returns the decision to send back to Claude Code. If a saved rule
    /// matches, returns immediately. Otherwise enqueues the request and
    /// suspends until the user decides (or the bridge times us out).
    func handlePreToolUse(_ payload: PreToolUsePayload, rawJSON: String) async -> ApprovalDecision {
        updateSession(from: payload)

        if let matched = matchRule(for: payload) {
            return matched
        }

        let approval = PendingApproval(
            id: UUID(),
            receivedAt: Date(),
            sessionID: payload.sessionID,
            toolName: payload.toolName,
            toolInput: payload.toolInput ?? [:],
            projectDirectory: payload.projectDirectory ?? payload.cwd,
            rawJSON: rawJSON
        )

        return await withCheckedContinuation { (cont: CheckedContinuation<ApprovalDecision, Never>) in
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
    }

    /// Called from the bridge when the hook script has been waiting too long.
    /// Resolves the head of the queue with `.ask` (Claude Code falls back to
    /// its native prompt) so we never block the script past its own timeout.
    func resolveTimeout(for id: UUID) {
        guard let cont = continuations.removeValue(forKey: id) else { return }
        pending.removeAll { $0.id == id }
        cont.resume(returning: .ask)
    }

    // MARK: - User-driven decisions

    /// Called by the UI / debug buttons. Resolves the matching pending entry
    /// and persists a rule if `as == .allowAlways`.
    func decide(_ id: UUID, as decision: ApprovalDecision) {
        guard let approval = pending.first(where: { $0.id == id }),
              let cont = continuations.removeValue(forKey: id)
        else { return }
        pending.removeAll { $0.id == id }

        if decision == .allowAlways {
            persistAllowRule(for: approval)
        }
        cont.resume(returning: decision)
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

    private func matchRule(for payload: PreToolUsePayload) -> ApprovalDecision? {
        for rule in rules where rule.matches(payload) {
            switch rule.decision {
            case .allow:    return .allow
            case .deny:     return .deny
            }
        }
        return nil
    }

    // MARK: - Sessions

    private func updateSession(from payload: PreToolUsePayload) {
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
                projectDirectory: payload.projectDirectory ?? payload.cwd
            )
        }
    }

    func recordNotification(_ payload: NotificationPayload) {
        guard let id = payload.sessionID else { return }
        let now = Date()
        if var existing = sessions[id] {
            existing.lastEventAt = now
            sessions[id] = existing
        } else {
            sessions[id] = SessionState(
                id: id,
                firstSeenAt: now,
                lastEventAt: now,
                lastTool: nil,
                projectDirectory: payload.projectDirectory
            )
        }
    }
}

// MARK: - Models

struct PendingApproval: Identifiable, Equatable {
    let id: UUID
    let receivedAt: Date
    let sessionID: String?
    let toolName: String
    let toolInput: [String: AnyJSON]
    let projectDirectory: String?
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
}

enum ApprovalDecision: Equatable {
    case allow
    case allowAlways
    case deny
    case ask

    /// JSON body Brow writes back on the HTTP response. Maps to Claude
    /// Code's `hookSpecificOutput.permissionDecision`.
    var hookOutputJSON: String {
        let value: String
        switch self {
        case .allow, .allowAlways: value = "allow"
        case .deny:                value = "deny"
        case .ask:                 value = "ask"
        }
        return #"{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"\#(value)"}}"#
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

    func matches(_ payload: PreToolUsePayload) -> Bool {
        guard toolName == payload.toolName else { return false }
        guard let matcher = argMatcher, !matcher.isEmpty else { return true }
        let target = payload.toolInput?["command"]?.asDisplayString
            ?? payload.toolInput?["file_path"]?.asDisplayString
            ?? payload.toolInput?["path"]?.asDisplayString
            ?? ""
        return target.contains(matcher)
    }

    static var rulesPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".brow/rules.json")
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
