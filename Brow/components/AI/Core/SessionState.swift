import Foundation

/// The single source of truth for all `AgentSession` mutations. A pure
/// reducer, ported from Open Island's `SessionState.apply` and trimmed to
/// Brow's 8-case `AgentEvent` (Tasks 1.2-1.4).
///
/// PURITY (hard constraint): no `Date()`/`Date.now`, no randomness, no I/O,
/// no singletons. Every mutation driven by `apply(_:)` reads its timestamp
/// off the incoming event. `resolvePermission`/`answerQuestion` are directly
/// invoked (not event-sourced) and have no event to read a timestamp off,
/// so the caller supplies one explicitly (`at timestamp: Date`) rather than
/// this reducer reaching for `Date()`. This purity is what makes the whole
/// session lifecycle unit-testable without wall-clock flakiness — see
/// `BrowTests/SessionStateTests.swift`.
struct SessionState: Equatable, Sendable {
    var sessionsByID: [String: AgentSession]

    init(sessionsByID: [String: AgentSession] = [:]) {
        self.sessionsByID = sessionsByID
    }

    // MARK: - apply

    /// Monotonic-`updatedAt` guard added on top of the reference: an event
    /// older than the session's current `updatedAt` is a stale/out-of-order
    /// delivery and must not resurrect or mutate the session (see
    /// `testCompletionAndMonotonicUpdatedAt`). `sessionStarted` is exempt —
    /// it's a fresh-start signal, not an incremental update, so it always
    /// applies. `markProcessLiveness` is also exempt (not part of `apply`);
    /// liveness polling has its own cadence, independent of event ordering.
    ///
    /// Upsert-on-any-event: unlike the reference (which relies on an
    /// `AppModel`-level JSONL/registry reconciliation pass Brow hasn't
    /// ported yet), every non-`sessionStarted` case below creates a session
    /// on first sighting instead of dropping the event when the id is
    /// unknown. Without this, a session Brow attaches to mid-flight (its
    /// `SessionStart` fired before the bridge was listening) never
    /// materializes — every later event is silently dropped and the v8
    /// list stays empty even though hook events are arriving. This mirrors
    /// the old `ClaudeCodeStore`'s `touchSession`/`recordUserPrompt`, which
    /// already created a session record from any event, not just
    /// `SessionStart`. `actionableStateResolved` is deliberately excluded —
    /// it only makes sense against a session already in an actionable
    /// phase, so it can't conjure one into existence.
    mutating func apply(_ event: AgentEvent) {
        switch event {
        case let .sessionStarted(payload):
            let preservedFirstSeenAt = sessionsByID[payload.sessionID]?.firstSeenAt
            var session = AgentSession(
                id: payload.sessionID,
                title: payload.title,
                tool: payload.tool,
                origin: payload.origin,
                attachmentState: .attached,
                phase: payload.initialPhase,
                summary: payload.summary,
                updatedAt: payload.timestamp,
                firstSeenAt: preservedFirstSeenAt,
                jumpTarget: payload.jumpTarget,
                claudeMetadata: payload.claudeMetadata,
                codexMetadata: payload.codexMetadata,
                isRemote: payload.isRemote,
                isHookManaged: payload.origin == .live
            )
            session.isSessionEnded = false
            session.isProcessAlive = true
            session.processNotSeenCount = 0
            upsert(session)

        case let .activityUpdated(payload):
            guard var session = upsertedSession(id: payload.sessionID, timestamp: payload.timestamp) else {
                return
            }

            let keepsPendingApproval = payload.phase == .running
                && session.phase == .waitingForApproval
                && session.permissionRequest != nil
            let keepsPendingQuestion = payload.phase == .running
                && session.phase == .waitingForAnswer
                && session.questionPrompt != nil

            if !(keepsPendingApproval || keepsPendingQuestion) {
                session.phase = payload.phase
                session.summary = payload.summary
                if payload.phase != .waitingForApproval { session.permissionRequest = nil }
                if payload.phase != .waitingForAnswer { session.questionPrompt = nil }
            }

            session.updatedAt = payload.timestamp
            upsert(session)

        case let .permissionRequested(payload):
            guard var session = upsertedSession(id: payload.sessionID, timestamp: payload.timestamp) else {
                return
            }

            session.phase = .waitingForApproval
            session.summary = payload.request.summary
            session.permissionRequest = payload.request
            session.questionPrompt = nil
            session.updatedAt = payload.timestamp
            upsert(session)

        case let .questionAsked(payload):
            guard var session = upsertedSession(id: payload.sessionID, timestamp: payload.timestamp) else {
                return
            }

            session.phase = .waitingForAnswer
            session.summary = payload.prompt.title
            session.questionPrompt = payload.prompt
            session.permissionRequest = nil
            session.updatedAt = payload.timestamp
            upsert(session)

        case let .sessionCompleted(payload):
            guard var session = upsertedSession(id: payload.sessionID, timestamp: payload.timestamp) else {
                return
            }

            session.phase = .completed
            session.summary = payload.summary
            session.permissionRequest = nil
            session.questionPrompt = nil
            session.updatedAt = payload.timestamp
            if payload.isSessionEnd == true {
                session.isSessionEnded = true
            }
            upsert(session)

        case let .jumpTargetUpdated(payload):
            guard var session = upsertedSession(id: payload.sessionID, timestamp: payload.timestamp) else {
                return
            }

            session.jumpTarget = payload.jumpTarget
            session.updatedAt = payload.timestamp
            upsert(session)

        case let .sessionMetadataUpdated(payload):
            guard var session = upsertedSession(id: payload.sessionID, timestamp: payload.timestamp) else {
                return
            }

            // Each field is independently optional — a Claude-only update
            // leaves `codexMetadata` nil meaning "untouched", not "clear it".
            if let claudeMetadata = payload.claudeMetadata { session.claudeMetadata = claudeMetadata }
            if let codexMetadata = payload.codexMetadata { session.codexMetadata = codexMetadata }
            session.updatedAt = payload.timestamp
            upsert(session)

        case let .actionableStateResolved(payload):
            guard var session = sessionsByID[payload.sessionID], payload.timestamp >= session.updatedAt else {
                return
            }

            guard session.phase == .waitingForApproval || session.phase == .waitingForAnswer else {
                return
            }

            session.phase = .running
            session.summary = payload.summary
            session.permissionRequest = nil
            session.questionPrompt = nil
            session.updatedAt = payload.timestamp
            upsert(session)
        }
    }

    /// Returns the existing session for `id` (subject to the monotonic
    /// `updatedAt` guard), or synthesizes a bare hook-managed one if this is
    /// the first event seen for `id`. `nil` means "drop the event" — either
    /// it's stale (older than the session's `updatedAt`) or the caller
    /// should not create a session (not used by `actionableStateResolved`,
    /// see its own guard). Synthesized sessions default to Claude Code —
    /// the only tool wired through `ClaudeEventMapping` today — and
    /// `isHookManaged = true`, matching every session this reducer sees in
    /// Brow's current Core scope.
    private func upsertedSession(id: String, timestamp: Date) -> AgentSession? {
        if let existing = sessionsByID[id] {
            return timestamp >= existing.updatedAt ? existing : nil
        }
        return AgentSession(
            id: id,
            title: "Claude Code",
            tool: .claudeCode,
            attachmentState: .attached,
            updatedAt: timestamp,
            isHookManaged: true,
            isProcessAlive: true
        )
    }

    // MARK: - Directly-invoked mutations (no event, caller supplies timestamp)

    mutating func resolvePermission(sessionID: String, _ resolution: PermissionResolution, at timestamp: Date) {
        guard var session = sessionsByID[sessionID] else {
            return
        }

        session.permissionRequest = nil

        switch resolution {
        case .allowOnce:
            session.phase = .running
            session.summary = "Permission approved. \(session.tool.displayName) continued the tool."
        case .deny:
            session.phase = .completed
            session.summary = "Permission denied."
        }

        session.updatedAt = timestamp
        upsert(session)
    }

    mutating func answerQuestion(sessionID: String, answers: [String: String], at timestamp: Date) {
        guard var session = sessionsByID[sessionID] else {
            return
        }

        session.questionPrompt = nil
        session.phase = .running

        let renderedAnswers = answers.keys.sorted().compactMap { key -> String? in
            guard let value = answers[key], !value.isEmpty else { return nil }
            return "\(key): \(value)"
        }.joined(separator: " · ")

        session.summary = renderedAnswers.isEmpty ? "Answered the question." : "Answered: \(renderedAnswers)"
        session.updatedAt = timestamp
        upsert(session)
    }

    // MARK: - Reconciliation / liveness

    @discardableResult
    mutating func reconcileAttachmentStates(_ updates: [String: SessionAttachmentState]) -> Bool {
        var changed = false

        for (sessionID, attachmentState) in updates {
            guard var session = sessionsByID[sessionID], session.attachmentState != attachmentState else {
                continue
            }

            session.attachmentState = attachmentState
            upsert(session)
            changed = true
        }

        return changed
    }

    /// Update process liveness for all tracked sessions based on process
    /// discovery. Hook-managed sessions get 2-consecutive-miss eviction:
    /// `processNotSeenCount` increments each miss and, at 2, the session is
    /// force-ended (`isSessionEnded = true, phase = .completed`) so it can't
    /// get stuck visible forever if its `SessionEnd` hook never arrives.
    mutating func markProcessLiveness(aliveIDs: Set<String>) {
        for (id, var session) in sessionsByID {
            // Remote sessions have no local process — stay alive as long as
            // the bridge is delivering hook events.
            if session.isRemote {
                continue
            }

            if session.isHookManaged {
                if session.isSessionEnded {
                    continue
                }

                if aliveIDs.contains(id) {
                    session.processNotSeenCount = 0
                } else {
                    session.processNotSeenCount += 1
                    if session.processNotSeenCount >= 2 {
                        session.isSessionEnded = true
                        session.phase = .completed
                    }
                }

                upsert(session)
                continue
            }

            if aliveIDs.contains(id) {
                session.isProcessAlive = true
                session.processNotSeenCount = 0
            } else {
                session.processNotSeenCount += 1
                session.isProcessAlive = session.processNotSeenCount < 2
            }

            upsert(session)
        }
    }

    /// Remove sessions that are no longer visible in the island. Returns
    /// `true` if any sessions were removed.
    @discardableResult
    mutating func removeInvisibleSessions() -> Bool {
        let before = sessionsByID.count
        sessionsByID = sessionsByID.filter { _, session in session.isVisibleInIsland }
        return sessionsByID.count != before
    }

    private mutating func upsert(_ session: AgentSession) {
        sessionsByID[session.id] = session
    }
}
