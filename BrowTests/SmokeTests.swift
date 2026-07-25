import XCTest
@testable import Brow

/// Bootstraps the test harness with a real assertion on existing code
/// (superseded by ValueTypeTests in Task 1.2). Asserts a genuine invariant.
final class SmokeTests: XCTestCase {
    func testAgentKindDisplayName() {
        // AIAgentKind.claudeCode.displayName is "Claude" (not "Claude Code") —
        // see Brow/components/AI/Models/AITask.swift.
        XCTAssertEqual(AIAgentKind.claudeCode.displayName, "Claude")
    }
}
