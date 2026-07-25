import XCTest
@testable import Brow

/// Tests `ClaudeEventMapping.mapClaudeEvent`, the adapter from Brow's
/// existing decoded Claude Code hook payloads (`ClaudeCodeIncomingEvent`)
/// into the `AgentEvent`s the `SessionState` reducer consumes.
///
/// The JSON below is the same fixture committed at
/// `BrowTests/Fixtures/claude_permission_request.json`, embedded here as a
/// string literal rather than loaded via `Bundle(for:)`. Classic PBXGroup
/// targets need an explicit Copy Bundle Resources phase entry for a test
/// bundle to see a fixture file at runtime, which is more wiring than this
/// one small JSON body is worth — the on-disk file stays as the readable,
/// diffable source of truth; this literal is a byte-for-byte copy of it.
final class ClaudeEventMappingTests: XCTestCase {
    // Mirrors BrowTests/Fixtures/claude_permission_request.json.
    private static let permissionRequestJSON = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "sess-abc123",
      "tool_name": "Edit",
      "tool_input": {
        "file_path": "/Users/tuan/project/foo.swift",
        "old_string": "let a = 1",
        "new_string": "let a = 2"
      },
      "tool_use_id": "toolu_01ABC",
      "project_dir": "/Users/tuan/project",
      "cwd": "/Users/tuan/project",
      "permission_mode": "default",
      "permission_suggestions": [
        {
          "type": "addRules",
          "destination": "session",
          "behavior": "allow",
          "rules": [
            { "toolName": "Edit", "ruleContent": "/Users/tuan/project/**" }
          ]
        },
        {
          "type": "setMode",
          "destination": "session",
          "mode": "acceptEdits"
        }
      ]
    }
    """

    private static let sessionStartJSON = """
    {
      "hook_event_name": "SessionStart",
      "session_id": "sess-abc123",
      "cwd": "/Users/tuan/project",
      "project_dir": "/Users/tuan/project",
      "source": "startup",
      "model": "claude-opus-4"
    }
    """

    func testPermissionRequestMapsToPermissionRequested() throws {
        let data = try XCTUnwrap(Self.permissionRequestJSON.data(using: .utf8))
        let incoming = try XCTUnwrap(ClaudeCodeIncomingEvent.decode(from: data))
        guard case .permissionRequest = incoming.event else {
            return XCTFail("Fixture did not decode as .permissionRequest — got \(incoming.event)")
        }

        let events = ClaudeEventMapping.mapClaudeEvent(incoming, context: nil)

        XCTAssertEqual(events.count, 1)
        guard case let .permissionRequested(payload)? = events.first else {
            return XCTFail("Expected exactly one .permissionRequested event, got \(events)")
        }
        XCTAssertEqual(payload.sessionID, "sess-abc123")
        XCTAssertEqual(payload.request.toolName, "Edit")
        XCTAssertEqual(payload.request.affectedPath, "/Users/tuan/project/foo.swift")
        XCTAssertEqual(payload.request.suggestedUpdates.count, 2)
    }

    // Task 2.8b fix round 1: `permissionSummary`'s unmatched-tool fallback
    // (the full "wants to run X" sentence) and `activityDescription`'s
    // unmatched-tool fallback (bare tool name) must stay independently
    // correct — a prior change collapsed both onto one shared function
    // and silently degraded the approval-card summary for any unlisted
    // tool (NotebookEdit, mcp__* tools, ...) to a bare tool name.
    private static let unlistedToolPermissionRequestJSON = """
    {
      "hook_event_name": "PermissionRequest",
      "session_id": "sess-nb1",
      "tool_name": "NotebookEdit",
      "tool_input": {},
      "tool_use_id": "toolu_nb1",
      "project_dir": "/Users/tuan/project",
      "cwd": "/Users/tuan/project",
      "permission_mode": "default"
    }
    """

    func testPermissionSummaryForUnlistedToolIsFullSentence() throws {
        let data = try XCTUnwrap(Self.unlistedToolPermissionRequestJSON.data(using: .utf8))
        let incoming = try XCTUnwrap(ClaudeCodeIncomingEvent.decode(from: data))

        let events = ClaudeEventMapping.mapClaudeEvent(incoming, context: nil)

        XCTAssertEqual(events.count, 1)
        guard case let .permissionRequested(payload)? = events.first else {
            return XCTFail("Expected exactly one .permissionRequested event, got \(events)")
        }
        // Unmatched tool (not in the Bash/Edit/Write/.../Task switch) must
        // fall through to the full sentence, NOT degrade to a bare tool
        // name — that's the regression the review caught.
        XCTAssertEqual(payload.request.summary, "Claude Code wants to run NotebookEdit.")
    }

    func testActivityDescriptionForUnlistedToolIsBareToolName() {
        // The chip/activity flavor keeps item 2's fix: unmatched tools show
        // the tool name, matching `ClaudeCodeStore.formatToolActivity`.
        XCTAssertEqual(
            ClaudeEventMapping.activityDescription(toolName: "NotebookEdit", toolInput: [:]),
            "NotebookEdit"
        )
    }

    func testSessionStartMapsToSessionStarted() throws {
        let data = try XCTUnwrap(Self.sessionStartJSON.data(using: .utf8))
        let incoming = try XCTUnwrap(ClaudeCodeIncomingEvent.decode(from: data))
        guard case .sessionStart = incoming.event else {
            return XCTFail("Fixture did not decode as .sessionStart — got \(incoming.event)")
        }

        let events = ClaudeEventMapping.mapClaudeEvent(incoming, context: nil)

        XCTAssertEqual(events.count, 1)
        guard case let .sessionStarted(payload)? = events.first else {
            return XCTFail("Expected exactly one .sessionStarted event, got \(events)")
        }
        XCTAssertEqual(payload.sessionID, "sess-abc123")
        XCTAssertEqual(payload.tool, .claudeCode)
        XCTAssertEqual(payload.title, "project")
    }
}
