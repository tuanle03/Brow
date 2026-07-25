import XCTest
@testable import Brow

/// End-to-end proof that mapping + reducer + model compose correctly: a
/// realistic sequence of decoded Claude Code hook payloads is driven through
/// `ClaudeEventMapping.mapClaudeEvent` → `AIAppModel.ingest`/`approve`,
/// asserting the full session lifecycle a real bridge run would produce
/// (Task 1.8). Complements `ClaudeEventMappingTests` (mapping only) and
/// `AIAppModelTests` (model only, hand-built `AgentEvent`s) — this is the
/// only place all three layers are driven together, JSON in.
@MainActor
final class AICoreEndToEndTests: XCTestCase {
    private static let sessionID = "sess-e2e-1"

    private static let sessionStartJSON = """
    {
      "hook_event_name": "SessionStart",
      "session_id": "\(sessionID)",
      "cwd": "/Users/tuan/project",
      "project_dir": "/Users/tuan/project",
      "source": "startup",
      "model": "claude-opus-4"
    }
    """

    private static let permissionRequestJSON = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "\(sessionID)",
      "tool_name": "Bash",
      "tool_input": { "command": "rm -rf /tmp/scratch" },
      "tool_use_id": "toolu_e2e_1",
      "project_dir": "/Users/tuan/project",
      "cwd": "/Users/tuan/project",
      "permission_mode": "default"
    }
    """

    private static let stopJSON = """
    {
      "hook_event_name": "Stop",
      "session_id": "\(sessionID)",
      "cwd": "/Users/tuan/project",
      "project_dir": "/Users/tuan/project"
    }
    """

    /// Decodes a fixture JSON string the same way `ClaudeCodeBridge` does
    /// (`ClaudeCodeIncomingEvent.decode(from:)`) and folds the mapped
    /// `AgentEvent`s straight into `model`.
    private func drive(_ json: String, into model: AIAppModel) throws {
        let data = try XCTUnwrap(json.data(using: .utf8))
        let incoming = try XCTUnwrap(ClaudeCodeIncomingEvent.decode(from: data))
        let events = ClaudeEventMapping.mapClaudeEvent(incoming, context: nil)
        model.ingest(events)
    }

    func testFullLifecycle_sessionStart_permissionRequest_approve_stop() throws {
        let model = AIAppModel()

        // 1. SessionStart -> session running.
        try drive(Self.sessionStartJSON, into: model)
        XCTAssertEqual(model.state.sessionsByID[Self.sessionID]?.phase, .running)

        // 2. PermissionRequest -> waitingForApproval, request stored. This is
        //    the exact ordering `ClaudeCodeBridge`'s `.permissionRequest` case
        //    now guarantees (Task 1.8): the mirror ingest happens before the
        //    store's blocking `await`, so the session is observably pending
        //    here — not skipped straight through to a post-decision state.
        try drive(Self.permissionRequestJSON, into: model)
        XCTAssertEqual(model.state.sessionsByID[Self.sessionID]?.phase, .waitingForApproval)
        let request = model.state.sessionsByID[Self.sessionID]?.permissionRequest
        XCTAssertEqual(request?.toolName, "Bash")

        // 3. approve(...) -> request cleared, back to running. Mirrors what
        //    the bridge's post-`await` `.actionableStateResolved` ingest (or,
        //    for the notch's own approve action, `AIAppModel.approve`) does.
        model.approve(sessionID: Self.sessionID, .allowOnce())
        XCTAssertNil(model.state.sessionsByID[Self.sessionID]?.permissionRequest)
        XCTAssertEqual(model.state.sessionsByID[Self.sessionID]?.phase, .running)

        // 4. Stop -> completed.
        try drive(Self.stopJSON, into: model)
        XCTAssertEqual(model.state.sessionsByID[Self.sessionID]?.phase, .completed)
    }
}
