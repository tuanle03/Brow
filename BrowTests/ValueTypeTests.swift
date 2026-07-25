import XCTest
@testable import Brow

final class ValueTypeTests: XCTestCase {
    func testAttention() {
        XCTAssertTrue(SessionPhase.waitingForApproval.requiresAttention)
        XCTAssertFalse(SessionPhase.running.requiresAttention)
    }

    func testBrand() {
        XCTAssertEqual(AgentTool.claudeCode.brandColorHex, "d97742")
    }
}
