import XCTest
@testable import Brow

/// The 5 TDD test cases from task-1.5-brief.md, adapted to the real
/// `AgentEvent` payload signatures from task 1.4 (`timestamp: Date`, not a
/// bare Int; `PermissionRequest.affectedPath` has no default;
/// `SessionActivityUpdated` field is `summary`/`phase`, not `activity`).
final class SessionStateTests: XCTestCase {
    /// Deterministic stand-in for wall-clock time — tests may use `Date`
    /// freely, only `SessionState` itself may not call `Date()`.
    private func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testSessionStartedCreatesRunning() {
        var st = SessionState()
        st.apply(.sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))))
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .running)
    }

    func testPermissionRequestSetsPhase() {
        var st = SessionState()
        st.apply(.sessionStarted(.init(sessionID: "s1", title: "r", tool: .claudeCode, summary: "", timestamp: ts(1))))
        st.apply(.permissionRequested(.init(
            sessionID: "s1",
            request: PermissionRequest(id: "p", title: "t", summary: "s", affectedPath: "", toolName: "Bash"),
            timestamp: ts(2)
        )))
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .waitingForApproval)
        XCTAssertNotNil(st.sessionsByID["s1"]?.permissionRequest)
    }

    func testResolveClearsRequest() {
        var st = SessionState()
        st.apply(.sessionStarted(.init(sessionID: "s1", title: "r", tool: .claudeCode, summary: "", timestamp: ts(1))))
        st.apply(.permissionRequested(.init(
            sessionID: "s1",
            request: PermissionRequest(id: "p", title: "t", summary: "s", affectedPath: "", toolName: "Bash"),
            timestamp: ts(2)
        )))
        st.resolvePermission(sessionID: "s1", .allowOnce(), at: ts(100))
        XCTAssertNil(st.sessionsByID["s1"]?.permissionRequest)
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .running)
        XCTAssertEqual(st.sessionsByID["s1"]?.updatedAt, ts(100)) // bumps updatedAt so 1.7's recency sort picks it up
    }

    func testCompletionAndMonotonicUpdatedAt() {
        var st = SessionState()
        st.apply(.sessionStarted(.init(sessionID: "s1", title: "r", tool: .claudeCode, summary: "", timestamp: ts(10))))
        st.apply(.sessionCompleted(.init(sessionID: "s1", summary: "done", timestamp: ts(20))))
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .completed)
        st.apply(.activityUpdated(.init(sessionID: "s1", summary: "late", phase: .running, timestamp: ts(5)))) // older
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .completed) // not resurrected
    }

    /// Reproduces the empty-v8-list bug: a session Brow attaches to
    /// mid-flight (its `SessionStart` fired before the bridge was
    /// listening) must still surface once a later hook event arrives for
    /// its id, not be silently dropped for lacking a prior
    /// `sessionStarted`. Covers both a lone `activityUpdated` and a lone
    /// `permissionRequested` as the first-ever event for a session id.
    func testEventForUnknownSessionCreatesVisibleSession() {
        var st = SessionState()
        st.apply(.activityUpdated(.init(sessionID: "missed-start", summary: "You: hi", phase: .running, timestamp: ts(1))))
        let created = st.sessionsByID["missed-start"]
        XCTAssertNotNil(created)
        XCTAssertTrue(created?.isHookManaged ?? false)
        XCTAssertTrue(created?.isVisibleInIsland ?? false)

        var st2 = SessionState()
        st2.apply(.permissionRequested(.init(
            sessionID: "missed-start-2",
            request: PermissionRequest(id: "p", title: "t", summary: "s", affectedPath: "", toolName: "Bash"),
            timestamp: ts(1)
        )))
        let createdViaPermission = st2.sessionsByID["missed-start-2"]
        XCTAssertEqual(createdViaPermission?.phase, .waitingForApproval)
        XCTAssertTrue(createdViaPermission?.isVisibleInIsland ?? false)
    }

    /// Fix round 1: `sessionCompleted` must NOT upsert-on-unknown, unlike
    /// `activityUpdated`/`permissionRequested`. `ClaudeEventMapping` maps
    /// Claude's `.stop` hook (end-of-turn, no `isSessionEnd`) to this same
    /// case, so if a `Stop` were the first event seen for a missed-
    /// SessionStart id, upserting would synthesize-then-immediately-complete
    /// a session the user never saw start or run — a spurious "done" card.
    func testSessionCompletedForUnknownSessionCreatesNothing() {
        var st = SessionState()
        st.apply(.sessionCompleted(.init(sessionID: "never-started", summary: "done", timestamp: ts(1))))
        XCTAssertTrue(st.sessionsByID.isEmpty)

        // Contrast: the actionable signals the mid-flight scenario needs
        // still upsert for the same unknown id.
        var st2 = SessionState()
        st2.apply(.activityUpdated(.init(sessionID: "never-started", summary: "hi", phase: .running, timestamp: ts(1))))
        XCTAssertNotNil(st2.sessionsByID["never-started"])

        var st3 = SessionState()
        st3.apply(.permissionRequested(.init(
            sessionID: "never-started",
            request: PermissionRequest(id: "p", title: "t", summary: "s", affectedPath: "", toolName: "Bash"),
            timestamp: ts(1)
        )))
        XCTAssertNotNil(st3.sessionsByID["never-started"])
    }

    /// Title backfill: a mid-flight upserted session starts with the generic
    /// "Claude Code" fallback; the first later event that names its project
    /// (derived from cwd) must replace it, and a real title must never be
    /// clobbered by a generic/missing incoming one.
    func testTitleBackfillFromLaterEvent() {
        // Missed SessionStart → upserted with the generic fallback title.
        var st = SessionState()
        st.apply(.activityUpdated(.init(sessionID: "s1", summary: "hi", phase: .running, timestamp: ts(1))))
        XCTAssertEqual(st.sessionsByID["s1"]?.title, SessionState.genericFallbackTitle)

        // A later event carrying a real project name backfills it.
        st.apply(.activityUpdated(.init(sessionID: "s1", summary: "You: go", phase: .running, timestamp: ts(2), title: "Brow")))
        XCTAssertEqual(st.sessionsByID["s1"]?.title, "Brow")

        // A subsequent generic/missing title must not clobber the real one.
        st.apply(.permissionRequested(.init(
            sessionID: "s1",
            request: PermissionRequest(id: "p", title: "t", summary: "s", affectedPath: "", toolName: "Bash"),
            timestamp: ts(3),
            title: nil
        )))
        XCTAssertEqual(st.sessionsByID["s1"]?.title, "Brow")
    }

    func testBackfilledTitleRule() {
        // Adopt a real name over the fallback / empty.
        XCTAssertEqual(SessionState.backfilledTitle(current: SessionState.genericFallbackTitle, incoming: "Brow"), "Brow")
        XCTAssertEqual(SessionState.backfilledTitle(current: "", incoming: "Brow"), "Brow")
        // Never clobber a real title, never adopt a generic/empty/nil one.
        XCTAssertEqual(SessionState.backfilledTitle(current: "Brow", incoming: "docs"), "Brow")
        XCTAssertEqual(SessionState.backfilledTitle(current: "Brow", incoming: nil), "Brow")
        XCTAssertEqual(SessionState.backfilledTitle(current: SessionState.genericFallbackTitle, incoming: SessionState.genericFallbackTitle), SessionState.genericFallbackTitle)
    }

    func testTwoMissEviction() {
        var st = SessionState()
        st.apply(.sessionStarted(.init(sessionID: "s1", title: "r", tool: .claudeCode, summary: "", timestamp: ts(1))))
        st.sessionsByID["s1"]?.isHookManaged = true
        st.markProcessLiveness(aliveIDs: []) // miss 1
        XCTAssertNotNil(st.sessionsByID["s1"])
        st.markProcessLiveness(aliveIDs: []) // miss 2 -> ended
        XCTAssertEqual(st.sessionsByID["s1"]?.isSessionEnded, true)
    }
}
