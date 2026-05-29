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
    // Snapshot of the previous refresh's "attention surface" so we can
    // play a sound exactly once per *new* pending approval / toast and
    // never repeatedly on re-render.
    private var previousPendingIDs: Set<UUID> = []
    private var previousTransientID: UUID?
    private var hasPerformedInitialRefresh = false
    /// Time until which the panel should stay in `.monitor` regardless
    /// of *pre-existing* queued approvals — armed briefly after every
    /// `decide(_:as:)` so the user always sees "ack + what AI is doing
    /// now" between back-to-back approvals from the same queue.
    private var monitorHoldUntil: Date?
    /// Timestamp the current hold was armed. A pending approval whose
    /// `receivedAt` is later than this — i.e. arrived *after* the user
    /// acted — yields the slot back to Approve immediately even with
    /// the hold timer still running. Without this, fresh requests get
    /// invisibly queued behind the hold and read as a "Monitor flash
    /// before Approve".
    private var monitorHoldArmedAt: Date?
    private var monitorHoldClearTask: Task<Void, Never>?
    private static let monitorHoldDuration: TimeInterval = 1.4

    private init() {
        self.store = ClaudeCodeStore.shared
        wireUp()
        refresh()
    }

    // MARK: - Forwarding to the underlying store

    /// Resolve the approval the panel is currently surfacing. Convenience
    /// wrapper around `ClaudeCodeStore.decide` — the registry doesn't own
    /// continuations. Also arms a brief monitor-hold so the next refresh
    /// shows the Monitor row of what the AI is doing before any queued
    /// approval slides into the same slot.
    func decide(_ approvalID: UUID, as decision: ApprovalDecision) {
        store.decide(approvalID, as: decision)
        armMonitorHold()
    }

    /// Force `.monitor` for `monitorHoldDuration` seconds *unless* a
    /// fresh PermissionRequest arrives in the meantime — the projection
    /// compares `pending.receivedAt` against `monitorHoldArmedAt` to let
    /// new requests override the hold. Rapid decisions chain: each
    /// extends the window instead of stacking sleep tasks.
    private func armMonitorHold() {
        let now = Date()
        monitorHoldArmedAt = now
        monitorHoldUntil = now.addingTimeInterval(Self.monitorHoldDuration)
        monitorHoldClearTask?.cancel()
        monitorHoldClearTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.monitorHoldDuration))
            await MainActor.run {
                guard let self else { return }
                if Task.isCancelled { return }
                self.monitorHoldUntil = nil
                self.monitorHoldArmedAt = nil
                self.refresh()
            }
        }
        // Force an immediate projection so the panel switches to Monitor
        // on the same frame the user clicked.
        refresh()
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
        let now = Date()
        // Hold is active when its expiry is still in the future *and*
        // every pending approval was added before the hold was armed —
        // a newer one short-circuits straight to Approve.
        let holdActive: Bool = {
            guard let until = monitorHoldUntil, until > now,
                  let armedAt = monitorHoldArmedAt else { return false }
            return !snapshot.pending.contains(where: { $0.receivedAt > armedAt })
        }()
        let projected = Self.project(snapshot, forceMonitor: holdActive)
        tasks = projected.tasks
        displayMode = projected.mode
        playSoundsForTransitions(snapshot: snapshot)
    }

    /// Plays exactly one sound when a *new* permission request lands or a
    /// *new* transient toast pops. Skipped on the first refresh after
    /// launch so we don't chirp every time the user restarts Brow with
    /// stale events still in the queue.
    private func playSoundsForTransitions(snapshot: Snapshot) {
        let newPendingIDs = Set(snapshot.pending.map(\.id))
        let arrivedPending = newPendingIDs.subtracting(previousPendingIDs)
        let newTransientID = snapshot.transient?.id

        if hasPerformedInitialRefresh {
            if !arrivedPending.isEmpty {
                AISoundEffects.play(.approvalArrived)
            } else if let id = newTransientID, id != previousTransientID {
                AISoundEffects.play(.notification)
            }
        }

        previousPendingIDs = newPendingIDs
        previousTransientID = newTransientID
        hasPerformedInitialRefresh = true
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
    /// registry. `forceMonitor` overrides the priority chain so a brief
    /// post-decision hold can stop a queued approval from slamming into
    /// the slot the user just resolved.
    private static func project(_ snapshot: Snapshot, forceMonitor: Bool = false) -> Projection {
        // Build a task per known session. Sessions are the source of
        // truth for "what's running"; pending approvals and the transient
        // toast attach to a session via `sessionID`.
        let pendingBySession = Dictionary(grouping: snapshot.pending) {
            $0.sessionID ?? ""
        }

        var tasks: [AITask] = snapshot.sessions.values.map { session in
            let approval = pendingBySession[session.id]?.first
            let askingQuestion: AIQuestion? = {
                guard snapshot.transient?.sessionID == session.id,
                      let q = snapshot.transient?.question else { return nil }
                return q
            }()

            let status: AITaskStatus
            if approval != nil {
                status = .pendingApproval
            } else if askingQuestion != nil {
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
                lastToolActivity: session.lastToolActivity,
                status: status,
                lastActivityAt: session.lastEventAt,
                currentApproval: approval,
                currentQuestion: askingQuestion
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
                lastToolActivity: ClaudeCodeStore.formatToolActivity(
                    toolName: approval.toolName,
                    toolInput: approval.toolInput
                ),
                status: .pendingApproval,
                lastActivityAt: approval.receivedAt,
                currentApproval: approval,
                currentQuestion: nil
            ))
        }

        // Actionable first (pendingApproval, askingQuestion) so the user
        // never misses a prompt buried under stale sessions. Within each
        // tier the most recently active task is at the top — strictly
        // by `lastActivityAt`, so a `.working` session from 3 minutes
        // ago no longer outranks an `.idle` one that just got a new
        // user prompt.
        tasks.sort { lhs, rhs in
            let lActionable = lhs.status == .pendingApproval || lhs.status == .askingQuestion
            let rActionable = rhs.status == .pendingApproval || rhs.status == .askingQuestion
            if lActionable != rActionable { return lActionable }
            return lhs.lastActivityAt > rhs.lastActivityAt
        }

        let mode: AIPanelMode
        if forceMonitor {
            mode = .monitor
        } else if let approving = tasks.first(where: { $0.status == .pendingApproval }) {
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
    // Sort uses a two-tier ordering now (actionable vs not, then by
    // `lastActivityAt`) so a per-status weight is no longer needed.
    // Leaving the file scoped to `private extension` keeps room for
    // future per-status helpers without disturbing imports.
}
