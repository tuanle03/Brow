import XCTest
@testable import Brow

final class AgentSessionVisibilityTests: XCTestCase {
    func testAttentionAlwaysVisible() {
        var s = AgentSession(id: "1", tool: .claudeCode); s.phase = .waitingForApproval; s.isProcessAlive = false
        XCTAssertTrue(s.isVisibleInIsland)
    }
    func testDeadRunningHidden() {
        var s = AgentSession(id: "2", tool: .claudeCode); s.phase = .running
        s.isProcessAlive = false; s.isHookManaged = true; s.isSessionEnded = true
        XCTAssertFalse(s.isVisibleInIsland)
    }
}
