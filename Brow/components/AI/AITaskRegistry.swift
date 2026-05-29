import Combine
import Foundation
import SwiftUI

/// UI-facing projection of `ClaudeCodeStore` (the only adapter in v1) into
/// the unified `AITask` model the panel renders. Holds no hook semantics
/// of its own — it observes `ClaudeCodeStore` and folds pending approvals,
/// sessions, and transient notifications into a single ordered list. The
/// panel binds to `tasks` + `displayMode`; everything else goes through
/// the underlying store's existing decide / answer plumbing.
@MainActor
final class AITaskRegistry: ObservableObject {
    static let shared = AITaskRegistry()

    @Published private(set) var tasks: [AITask] = []
    /// Which sub-view the panel should render right now. Derived from
    /// `tasks` — pending approval > question > monitor list.
    @Published private(set) var displayMode: AIPanelMode = .monitor

    private let store: ClaudeCodeStore
    private var cancellables: Set<AnyCancellable> = []

    private init() {
        self.store = ClaudeCodeStore.shared
        wireUp()
        refresh()
    }

    // MARK: - Forwarding to the underlying store

    /// Resolve the approval the panel is currently surfacing. Convenience
    /// wrapper around `ClaudeCodeStore.decide` — the registry doesn't own
    /// continuations.
    func decide(_ approvalID: UUID, as decision: ApprovalDecision) {
        store.decide(approvalID, as: decision)
    }

    func dismissTransientNotification() {
        store.dismissTransientNotification()
    }

    // MARK: - Wiring

    private func wireUp() {
        // Any change to pending / sessions / transient triggers a fold.
        // We don't differentiate which one moved — the projection is cheap
        // (< ~10 sessions in practice) and avoids partial-update bugs.
        // Three separate sinks instead of `Publishers.MergeMany` because
        // each @Published has a different Output type.
        store.$pending
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        store.$sessions
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
        store.$transientNotification
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)
    }

    private func refresh() {
        let snapshot = Snapshot(
            pending: store.pending,
            sessions: store.sessions,
            transient: store.transientNotification
        )
        let projected = Self.project(snapshot)
        tasks = projected.tasks
        displayMode = projected.mode
    }

    // MARK: - Projection

    private struct Snapshot {
        let pending: [PendingApproval]
        let sessions: [String: SessionState]
        let transient: TransientNotification?
    }

    private struct Projection {
        let tasks: [AITask]
        let mode: AIPanelMode
    }

    /// Fold the store snapshot into ordered `AITask`s + the panel mode.
    /// Pure function — easy to unit-test once we add tests for the
    /// registry.
    private static func project(_ snapshot: Snapshot) -> Projection {
        // Build a task per known session. Sessions are the source of
        // truth for "what's running"; pending approvals and the transient
        // toast attach to a session via `sessionID`.
        let pendingBySession = Dictionary(grouping: snapshot.pending) {
            $0.sessionID ?? ""
        }

        var tasks: [AITask] = snapshot.sessions.values.map { session in
            let approval = pendingBySession[session.id]?.first
            let isAsking = snapshot.transient?.sessionID == session.id
                && snapshot.transient?.body.hasPrefix("Claude is asking") == true

            let status: AITaskStatus
            if approval != nil {
                status = .pendingApproval
            } else if isAsking {
                status = .askingQuestion
            } else if let lastTool = session.lastTool, !lastTool.isEmpty {
                status = .working("\(lastTool)…")
            } else {
                status = .idle
            }

            return AITask(
                id: session.id,
                agentKind: .claudeCode,
                sessionID: session.id,
                projectDirectory: session.projectDirectory,
                terminalAppHint: session.terminalAppHint,
                userPrompt: session.lastUserPrompt,
                status: status,
                lastActivityAt: session.lastEventAt,
                currentApproval: approval,
                currentQuestion: isAsking
                    ? AIQuestion(text: snapshot.transient?.body ?? "", options: [])
                    : nil
            )
        }

        // Orphan pending approvals (sessions that didn't fire SessionStart):
        // synthesize a placeholder task so the panel never drops a request
        // on the floor.
        for approval in snapshot.pending where (approval.sessionID ?? "").isEmpty
            || snapshot.sessions[approval.sessionID ?? ""] == nil
        {
            tasks.append(AITask(
                id: approval.id.uuidString,
                agentKind: .claudeCode,
                sessionID: approval.sessionID,
                projectDirectory: approval.projectDirectory,
                terminalAppHint: nil,
                userPrompt: nil,
                status: .pendingApproval,
                lastActivityAt: approval.receivedAt,
                currentApproval: approval,
                currentQuestion: nil
            ))
        }

        // Pending / asking first (newest by receivedAt), then everything
        // else by recency. Stable ordering keeps the highlighted row from
        // jumping around as background tools fire.
        tasks.sort { lhs, rhs in
            let lp = lhs.status.priority
            let rp = rhs.status.priority
            if lp != rp { return lp > rp }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }

        let mode: AIPanelMode
        if let approving = tasks.first(where: { $0.status == .pendingApproval }) {
            mode = .approve(taskID: approving.id)
        } else if let asking = tasks.first(where: { $0.status == .askingQuestion }) {
            mode = .ask(taskID: asking.id)
        } else {
            mode = .monitor
        }

        return Projection(tasks: tasks, mode: mode)
    }
}

private extension AITaskStatus {
    /// Sort weight for the `tasks` list. Higher = more attention-grabbing.
    var priority: Int {
        switch self {
        case .pendingApproval: return 4
        case .askingQuestion:  return 3
        case .working:         return 2
        case .done:            return 1
        case .idle:            return 0
        }
    }
}
