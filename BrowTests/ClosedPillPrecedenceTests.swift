import XCTest
@testable import Brow

/// TDD test for Task 2.4's closed-pill precedence resolver
/// (`AIAppModel.closedPillContent`). AI attention always wins, even over a
/// currently-playing song — every tie in the aiAttention > aiRunning >
/// music > mascot > empty ladder gets its own case here.
@MainActor
final class ClosedPillPrecedenceTests: XCTestCase {
    private func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func upsert(_ model: AIAppModel, _ session: AgentSession) {
        model.state.sessionsByID[session.id] = session
    }

    func testAttentionBeatsMusic() {
        let m = AIAppModel()
        upsert(m, AgentSession(id: "s1", tool: .claudeCode, phase: .waitingForApproval, updatedAt: ts(1)))

        XCTAssertEqual(
            m.closedPillContent(musicPlaying: true, mascotEnabled: true),
            .aiAttention(sessionID: "s1")
        )
    }

    func testRunningBeatsMusic() {
        let m = AIAppModel()
        upsert(m, AgentSession(id: "s1", tool: .claudeCode, phase: .running, updatedAt: ts(1), isProcessAlive: true))

        XCTAssertEqual(m.closedPillContent(musicPlaying: true, mascotEnabled: true), .aiRunning)
    }

    func testMusicBeatsMascot() {
        let m = AIAppModel()

        XCTAssertEqual(m.closedPillContent(musicPlaying: true, mascotEnabled: true), .music)
    }

    func testMascotWhenOnlyMascotEnabled() {
        let m = AIAppModel()

        XCTAssertEqual(m.closedPillContent(musicPlaying: false, mascotEnabled: true), .mascot)
    }

    func testEmptyWhenNothing() {
        let m = AIAppModel()

        XCTAssertEqual(m.closedPillContent(musicPlaying: false, mascotEnabled: false), .empty)
    }

    /// Default `isProcessAlive: false`, not hook-managed, not demo — so
    /// `AgentSession.isVisibleInIsland` is false despite `phase == .running`,
    /// and the resolver must not surface it as `.aiRunning`.
    func testNonVisibleRunningSessionDoesNotTriggerRunning() {
        let m = AIAppModel()
        upsert(m, AgentSession(id: "s1", tool: .claudeCode, phase: .running, updatedAt: ts(1)))

        XCTAssertEqual(m.closedPillContent(musicPlaying: false, mascotEnabled: false), .empty)
    }

    /// Documented tiebreak: when more than one visible session needs
    /// attention, the most recently updated one wins.
    func testAttentionTiebreakPicksMostRecentlyUpdated() {
        let m = AIAppModel()
        upsert(m, AgentSession(id: "old", tool: .claudeCode, phase: .waitingForApproval, updatedAt: ts(1)))
        upsert(m, AgentSession(id: "new", tool: .codex, phase: .waitingForAnswer, updatedAt: ts(2)))

        XCTAssertEqual(
            m.closedPillContent(musicPlaying: false, mascotEnabled: false),
            .aiAttention(sessionID: "new")
        )
    }
}
