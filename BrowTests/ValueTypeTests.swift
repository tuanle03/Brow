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

    func testPermissionRequestRoundTripsViaCodable() throws {
        let request = PermissionRequest(
            id: "toolu_1",
            title: "Allow Bash",
            summary: "Claude wants to run Bash.",
            affectedPath: "/tmp"
        )
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(PermissionRequest.self, from: data)
        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.title, "Allow Bash")
        XCTAssertEqual(decoded.summary, "Claude wants to run Bash.")
        XCTAssertEqual(decoded.primaryActionTitle, "Allow")
        XCTAssertEqual(decoded.secondaryActionTitle, "Deny")
    }

    func testClaudePermissionUpdateAddDirectoriesRoundTrips() throws {
        let update = ClaudePermissionUpdate.addDirectories(destination: .session, directories: ["/tmp", "/var"])
        let data = try JSONEncoder().encode(update)
        let decoded = try JSONDecoder().decode(ClaudePermissionUpdate.self, from: data)
        XCTAssertEqual(decoded, update)
        guard case let .addDirectories(destination, directories) = decoded else {
            return XCTFail("expected .addDirectories")
        }
        XCTAssertEqual(destination, .session)
        XCTAssertEqual(directories, ["/tmp", "/var"])
    }

    func testQuestionOptionAllowsFreeform() {
        let other = QuestionOption(label: "Other", allowsFreeform: true)
        XCTAssertTrue(other.allowsFreeform)
        XCTAssertEqual(other.label, "Other")
    }
}
