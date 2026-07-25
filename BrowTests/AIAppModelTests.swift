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
}
