import XCTest
@testable import Brow

/// TDD test for Task 1.7's `AIAppModel` — the `@Observable` owner of the
/// ported `SessionState` reducer, fed additively by the bridge alongside
/// (not instead of) `ClaudeCodeStore`. See `AIAppModel.swift`'s doc comment
/// for why `approve`/`answer` here only mutate the reducer and don't touch
/// any HTTP continuation yet.
@MainActor
final class AIAppModelTests: XCTestCase {
    private func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    func testIngestUpdatesState() {
        let m = AIAppModel()
        m.ingest([.sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1)))])
        XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .running)
    }

    func testApproveClearsRequestAndResumesRunning() {
        let m = AIAppModel()
        m.ingest([
            .sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))),
            .permissionRequested(.init(
                sessionID: "s1",
                request: PermissionRequest(id: "p", title: "t", summary: "s", affectedPath: "", toolName: "Bash"),
                timestamp: ts(2)
            )),
        ])
        XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .waitingForApproval)

        m.approve(sessionID: "s1", .allowOnce())

        XCTAssertNil(m.state.sessionsByID["s1"]?.permissionRequest)
        XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .running)
    }

    /// Phase-2 review fix: `ContentView.handleAIAutoExpansionChange(false)`
    /// now calls `dismissCompletion` itself the moment the notch collapses
    /// with a completion card showing, instead of relying solely on the
    /// `.task(id:)` 5s auto-dismiss timer — that timer gets cancelled the
    /// instant the notch closes (view torn down), so it never ran and the
    /// card kept re-presenting on every later manual AI-tab open. This
    /// locks the invariant that fix depends on: once a completion has been
    /// presented and dismissed, it stays hidden for every later query, not
    /// just the query immediately after the dismissal.
    func testDismissedCompletionStaysHiddenOnLaterQuery() {
        let m = AIAppModel()
        m.ingest([
            .sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))),
            .sessionCompleted(.init(sessionID: "s1", summary: "Done.", timestamp: ts(100))),
        ])
        let session = try! XCTUnwrap(m.completionCardSession(now: ts(105)))

        m.dismissCompletion(session)

        // Immediately after dismissal.
        XCTAssertNil(m.completionCardSession(now: ts(106)))
        // A later manual AI-tab open, still well within the 5-minute
        // freshness window — must NOT re-present.
        XCTAssertNil(m.completionCardSession(now: ts(100 + 4 * 60)))
    }
}
