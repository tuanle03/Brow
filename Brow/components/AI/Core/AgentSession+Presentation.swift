import Foundation

/// Task 2.5: presentation/derivation helpers the session list (and its
/// ranking logic in `AIAppModel`) read off `AgentSession`. Ported from the
/// reference's `AgentSession+Presentation.swift`, trimmed to what this
/// task's row/list actually use — the reference's headline also folds in a
/// worktree-branch segment, which Brow's `AgentSession` has no field for
/// yet (dropped along with `worktreeBranch` when `ClaudeSessionMetadata`
/// was trimmed — see that type's doc comment).
extension AgentSession {
    /// Reference's `AgentSession.staleCompletedDisplayThreshold` — how long
    /// a completed session sits before folding into the low-priority/idle
    /// presentation.
    static let staleCompletedThreshold: TimeInterval = 5 * 60

    /// The tool the agent is currently invoking, if any — sourced from
    /// whichever per-tool metadata bag is populated. Ported from the
    /// reference's `currentToolName`.
    var currentToolName: String? {
        claudeMetadata?.currentTool ?? codexMetadata?.currentTool
    }

    /// Workspace name for headline display: the jump target's workspace
    /// name if present, else the tail piece of `title` after a "·"
    /// separator, else `title` itself. Ported from the reference's
    /// `spotlightWorkspaceName`.
    var spotlightWorkspaceName: String {
        if let workspace = jumpTarget?.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            return workspace
        }

        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let pieces = trimmedTitle.split(separator: "·", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if pieces.count == 2, !pieces[1].isEmpty {
            return pieces[1]
        }

        return trimmedTitle
    }

    /// The session's opening prompt (session topic), falling back to the
    /// latest prompt if no initial one was recorded. Ported from the
    /// reference's `spotlightHeadlinePromptText`.
    private var spotlightHeadlinePromptText: String? {
        let initial = claudeMetadata?.initialUserPrompt ?? codexMetadata?.initialUserPrompt
        let latest = claudeMetadata?.lastUserPrompt ?? codexMetadata?.lastUserPrompt
        return (initial?.isEmpty == false ? initial : nil) ?? (latest?.isEmpty == false ? latest : nil)
    }

    /// "workspace · prompt" headline for the session row. Ported from the
    /// reference's `spotlightHeadlineText`, minus the worktree-branch
    /// segment (see this file's doc comment).
    var spotlightHeadline: String {
        guard let prompt = spotlightHeadlinePromptText else {
            return spotlightWorkspaceName
        }
        return spotlightWorkspaceName.isEmpty ? prompt : "\(spotlightWorkspaceName) · \(prompt)"
    }

    /// The most recent user prompt for this session (latest, else the
    /// opening one) — `nil` when neither is populated. Used for the row
    /// subtitle and expanded detail's "You: …" line.
    var latestUserPromptText: String? {
        let latest = claudeMetadata?.lastUserPrompt ?? codexMetadata?.lastUserPrompt
        let initial = claudeMetadata?.initialUserPrompt ?? codexMetadata?.initialUserPrompt
        return (latest?.isEmpty == false ? latest : nil) ?? (initial?.isEmpty == false ? initial : nil)
    }

    /// Last tool activity ("Tool: input-preview", or just the tool name) —
    /// `nil` when no tool is currently recorded. Shown in the expanded detail.
    var currentActivityText: String? {
        guard let tool = currentToolName, !tool.isEmpty else { return nil }
        let preview = claudeMetadata?.currentToolInputPreview ?? codexMetadata?.currentCommandPreview
        if let preview, !preview.isEmpty { return "\(tool): \(preview)" }
        return tool
    }

    /// One-line row subtitle: the last user prompt as "You: …" when we have
    /// one (reads like a TODO of asks), else the current status `summary`.
    var rowSubtitle: String {
        if let prompt = latestUserPromptText { return "You: \(prompt)" }
        return summary
    }

    /// v8 UI-only staleness: keeps `phase` unchanged, but lets callers fold
    /// older completed rows into a lower-priority/dimmed presentation.
    /// Pure — both `now` and `threshold` are caller-supplied. Ported from
    /// the reference's `isStaleCompletedForIsland(at:threshold:)`.
    func isStaleCompleted(now: Date, threshold: TimeInterval = AgentSession.staleCompletedThreshold) -> Bool {
        phase == .completed && now.timeIntervalSince(updatedAt) >= threshold
    }
}
