import XCTest
@testable import Brow

/// TDD test for Task 2.2's `AIAppModel.islandClosedMode` — the pure
/// aggregation that drives `UnifiedBarsGlyph`'s closed-pill glyph. Precedence
/// is waiting > running > idle, evaluated only over sessions visible in the
/// island (`AgentSession.isVisibleInIsland`).
@MainActor
final class UnifiedBarsModeTests: XCTestCase {
    private func session(_ id: String, phase: SessionPhase, isProcessAlive: Bool = true) -> AgentSession {
        var s = AgentSession(id: id, tool: .claudeCode)
        s.phase = phase
        s.isProcessAlive = isProcessAlive
        return s
    }

    func testWaitingBeatsRunning() {
        let m = AIAppModel()
        m.state.sessionsByID = [
            "a": session("a", phase: .waitingForApproval),
            "b": session("b", phase: .running),
        ]
        XCTAssertEqual(m.islandClosedMode, .waiting)
    }

    func testRunningBeatsIdle() {
        let m = AIAppModel()
        m.state.sessionsByID = [
            "a": session("a", phase: .running),
            "b": session("b", phase: .completed, isProcessAlive: false),
        ]
        XCTAssertEqual(m.islandClosedMode, .running)
    }

    func testEmptyIsIdle() {
        let m = AIAppModel()
        XCTAssertEqual(m.islandClosedMode, .idle)
    }

    func testAllCompletedIsIdle() {
        let m = AIAppModel()
        m.state.sessionsByID = [
            "a": session("a", phase: .completed, isProcessAlive: false),
        ]
        XCTAssertEqual(m.islandClosedMode, .idle)
    }

    func testNotVisibleRunningDoesNotForceRunning() {
        // A running session with a dead process and no hook management is
        // not visible in the island (see `isVisibleInIsland`) — it must not
        // pull the glyph into `.running`.
        let m = AIAppModel()
        m.state.sessionsByID = [
            "a": session("a", phase: .running, isProcessAlive: false),
        ]
        XCTAssertEqual(m.islandClosedMode, .idle)
    }
}
