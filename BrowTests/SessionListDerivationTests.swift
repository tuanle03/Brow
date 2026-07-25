import XCTest
@testable import Brow

/// TDD test for Task 2.5's pure ranking/grouping/staleness logic that
/// drives the v8 session list: `AIAppModel.displayPriority`,
/// `surfacedSessions(now:)`, `islandSessionSections(group:sort:now:)`, and
/// `AgentSession.isStaleCompleted(now:threshold:)`. Every case supplies its
/// own `now`/`threshold` — no wall-clock reads, so results are
/// deterministic.
@MainActor
final class SessionListDerivationTests: XCTestCase {
    private func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: - displayPriority

    func testDisplayPriorityOrdersAttentionAboveRunningAboveCompleted() {
        let m = AIAppModel()
        let now = ts(10_000)

        var attention = AgentSession(id: "a", tool: .claudeCode)
        attention.phase = .waitingForApproval
        attention.updatedAt = now

        var running = AgentSession(id: "r", tool: .claudeCode)
        running.phase = .running
        running.updatedAt = now

        var completed = AgentSession(id: "c", tool: .claudeCode)
        completed.phase = .completed
        completed.updatedAt = now

        let attentionScore = m.displayPriority(for: attention, now: now)
        let runningScore = m.displayPriority(for: running, now: now)
        let completedScore = m.displayPriority(for: completed, now: now)

        XCTAssertGreaterThan(attentionScore, runningScore)
        XCTAssertGreaterThan(runningScore, completedScore)
    }

    // MARK: - surfacedSessions(now:)

    func testSurfacedSessionsExcludesNonVisible() {
        let m = AIAppModel()
        let now = ts(10_000)

        var visible = AgentSession(id: "visible", tool: .claudeCode)
        visible.phase = .running
        visible.isProcessAlive = true
        visible.updatedAt = now

        var hidden = AgentSession(id: "hidden", tool: .claudeCode)
        hidden.phase = .running
        hidden.isProcessAlive = false
        hidden.isHookManaged = false
        hidden.updatedAt = now

        m.state.sessionsByID = ["visible": visible, "hidden": hidden]

        let surfaced = m.surfacedSessions(now: now)

        XCTAssertEqual(surfaced.map(\.id), ["visible"])
    }

    // MARK: - islandSessionSections(group: .state)

    func testGroupByStateBucketsCorrectly() {
        let m = AIAppModel()
        let now = ts(10_000)

        var approval = AgentSession(id: "approval", tool: .claudeCode)
        approval.phase = .waitingForApproval
        approval.updatedAt = now

        var running = AgentSession(id: "running", tool: .claudeCode)
        running.phase = .running
        running.isProcessAlive = true
        running.updatedAt = now

        // Completed sessions are only visible in the island while their
        // hook connection is still attached (isSessionEnded == false) —
        // matches AgentSession.isVisibleInIsland's real-world rule for a
        // "just finished a turn, hasn't received SessionEnd yet" session.
        var justDone = AgentSession(id: "justDone", tool: .claudeCode)
        justDone.phase = .completed
        justDone.isHookManaged = true
        justDone.isSessionEnded = false
        justDone.updatedAt = now

        var staleIdle = AgentSession(id: "staleIdle", tool: .claudeCode)
        staleIdle.phase = .completed
        staleIdle.isHookManaged = true
        staleIdle.isSessionEnded = false
        staleIdle.updatedAt = now.addingTimeInterval(-3_600)

        m.state.sessionsByID = [
            "approval": approval,
            "running": running,
            "justDone": justDone,
            "staleIdle": staleIdle,
        ]

        let sections = m.islandSessionSections(group: .state, sort: .attention, now: now)
        let sectionsByID = Dictionary(uniqueKeysWithValues: sections.map { ($0.id, $0) })

        XCTAssertEqual(sectionsByID["state-approval"]?.sessions.map(\.id), ["approval"])
        XCTAssertEqual(sectionsByID["state-running"]?.sessions.map(\.id), ["running"])
        XCTAssertEqual(sectionsByID["state-done"]?.sessions.map(\.id), ["justDone"])
        XCTAssertEqual(sectionsByID["state-idle"]?.sessions.map(\.id), ["staleIdle"])
        XCTAssertNil(sectionsByID["state-answer"])
    }

    // MARK: - islandSessionSections(sort: .lastUpdate)

    func testSortByLastUpdateOrdersByUpdatedAt() {
        let m = AIAppModel()
        let now = ts(10_000)

        var older = AgentSession(id: "older", tool: .claudeCode)
        older.phase = .completed
        older.isHookManaged = true
        older.isSessionEnded = false
        older.updatedAt = now.addingTimeInterval(-600)

        var newer = AgentSession(id: "newer", tool: .claudeCode)
        newer.phase = .completed
        newer.isHookManaged = true
        newer.isSessionEnded = false
        newer.updatedAt = now.addingTimeInterval(-10)

        m.state.sessionsByID = ["older": older, "newer": newer]

        let sections = m.islandSessionSections(group: .none, sort: .lastUpdate, now: now)

        XCTAssertEqual(sections.first?.sessions.map(\.id), ["newer", "older"])
    }

    // MARK: - AgentSession.isStaleCompleted(now:threshold:)

    func testIsStaleCompletedThreshold() {
        var session = AgentSession(id: "s", tool: .claudeCode)
        session.phase = .completed
        session.updatedAt = ts(10_000)

        XCTAssertTrue(session.isStaleCompleted(now: ts(10_000 + 300), threshold: 300))
        XCTAssertFalse(session.isStaleCompleted(now: ts(10_000 + 299), threshold: 300))
    }
}
