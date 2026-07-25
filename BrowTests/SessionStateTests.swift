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
        st.resolvePermission(sessionID: "s1", .allowOnce())
        XCTAssertNil(st.sessionsByID["s1"]?.permissionRequest)
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .running)
    }

    func testCompletionAndMonotonicUpdatedAt() {
        var st = SessionState()
        st.apply(.sessionStarted(.init(sessionID: "s1", title: "r", tool: .claudeCode, summary: "", timestamp: ts(10))))
        st.apply(.sessionCompleted(.init(sessionID: "s1", summary: "done", timestamp: ts(20))))
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .completed)
        st.apply(.activityUpdated(.init(sessionID: "s1", summary: "late", phase: .running, timestamp: ts(5)))) // older
        XCTAssertEqual(st.sessionsByID["s1"]?.phase, .completed) // not resurrected
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
