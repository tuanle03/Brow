import XCTest
@testable import Brow

final class AgentEventCodableTests: XCTestCase {
    func testPermissionRequestedRoundTrips() throws {
        let req = PermissionRequest(id: "p1", title: "Run tool", summary: "$ ls", affectedPath: "/tmp", toolName: "Bash")
        let ev = AgentEvent.permissionRequested(.init(sessionID: "s1", request: req, timestamp: Date(timeIntervalSince1970: 1000)))
        let data = try JSONEncoder().encode(ev)
        let back = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(ev, back)
    }

    func testSessionStartedRoundTrips() throws {
        let ev = AgentEvent.sessionStarted(.init(
            sessionID: "s1",
            title: "Fix bug",
            tool: .claudeCode,
            summary: "Working on it",
            timestamp: Date(timeIntervalSince1970: 2000)
        ))
        let data = try JSONEncoder().encode(ev)
        let back = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(ev, back)
    }

    func testSessionCompletedRoundTrips() throws {
        let ev = AgentEvent.sessionCompleted(.init(
            sessionID: "s1",
            summary: "Done",
            timestamp: Date(timeIntervalSince1970: 3000),
            isInterrupt: false,
            isSessionEnd: true
        ))
        let data = try JSONEncoder().encode(ev)
        let back = try JSONDecoder().decode(AgentEvent.self, from: data)
        XCTAssertEqual(ev, back)
    }
}
