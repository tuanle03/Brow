import XCTest
@testable import Brow

/// Task 2.9 (safety valve). Two guards for this task's actual surface area:
///
/// 1. The Allow / Deny / Always-allow **directive JSON shapes** the approval
///    round-trip sends back to Claude Code. 2.9 kept the continuation in
///    `ClaudeCodeStore` (see the task report for why), so the shipping path
///    is still `ClaudeCodeStore.decide(_:as:)` → `ApprovalDecision.hookOutputJSON`.
///    These assertions lock that wire shape so a future refactor can't
///    silently change what the `claude` hook receives.
/// 2. The new `AIAppModel.completionCardSession(now:)` driver that replaced
///    the old `ClaudeCodeStore.transientNotification` `.stopped`-toast
///    coupling as the completion card's trigger.
@MainActor
final class ApprovalRoundTripTests: XCTestCase {
    private func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func approval(suggestions: [PermissionSuggestion] = []) -> PendingApproval {
        PendingApproval(
            id: UUID(),
            receivedAt: ts(1),
            sessionID: "s1",
            toolName: "Bash",
            toolInput: [:],
            projectDirectory: "/repo",
            suggestions: suggestions,
            rawJSON: "{}"
        )
    }

    private func decode(_ json: String) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }

    // MARK: - Directive shapes

    func testAllowDirectiveShape() {
        let json = ApprovalDecision.allow.hookOutputJSON(for: approval())
        let hook = decode(json)?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hook?["hookEventName"] as? String, "PermissionRequest")
        let decision = hook?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertNil(decision?["updatedPermissions"])
    }

    func testDenyDirectiveShape() {
        let json = ApprovalDecision.deny.hookOutputJSON(for: approval())
        let hook = decode(json)?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hook?["hookEventName"] as? String, "PermissionRequest")
        XCTAssertEqual((hook?["decision"] as? [String: Any])?["behavior"] as? String, "deny")
    }

    func testAlwaysAllowDirectiveCarriesUpdatedPermissions() {
        let suggestion = PermissionSuggestion(
            type: "addRules",
            destination: "session",
            behavior: "allow",
            rules: [.init(toolName: "Bash", ruleContent: nil)],
            mode: nil
        )
        let json = ApprovalDecision.allowAlways.hookOutputJSON(for: approval(suggestions: [suggestion]))
        let decision = (decode(json)?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        let updates = decision?["updatedPermissions"] as? [[String: Any]]
        XCTAssertEqual(updates?.count, 1)
        XCTAssertEqual(updates?.first?["type"] as? String, "addRules")
    }

    func testAskDirectiveIsEmptyEnvelope() {
        // The 55s-timeout fallback: an empty body so Claude Code shows its
        // own native prompt.
        XCTAssertEqual(ApprovalDecision.ask.hookOutputJSON(for: approval()), "{}")
    }

    // MARK: - Completion-card driver

    private func completedModel(at completedAt: TimeInterval) -> AIAppModel {
        let m = AIAppModel()
        m.ingest([
            .sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))),
            .sessionCompleted(.init(sessionID: "s1", summary: "Done.", timestamp: ts(completedAt))),
        ])
        return m
    }

    func testFreshCompletionShowsCard() {
        let m = completedModel(at: 100)
        // now == just after completion → within the 5min stale window.
        XCTAssertEqual(m.completionCardSession(now: ts(130))?.id, "s1")
    }

    func testStaleCompletionDoesNotShowCard() {
        let m = completedModel(at: 100)
        // 6 minutes later → past the 5min staleCompletedThreshold.
        XCTAssertNil(m.completionCardSession(now: ts(100 + 6 * 60)))
    }

    func testDismissHidesCardUntilNewerCompletion() {
        let m = completedModel(at: 100)
        let session = try! XCTUnwrap(m.completionCardSession(now: ts(130)))

        m.dismissCompletion(session)
        XCTAssertNil(m.completionCardSession(now: ts(130)), "dismissed completion should not re-show")

        // A newer completion of the same session (next turn) re-shows.
        m.ingest([.sessionCompleted(.init(sessionID: "s1", summary: "Done again.", timestamp: ts(200)))])
        XCTAssertEqual(m.completionCardSession(now: ts(210))?.id, "s1")
    }
}
