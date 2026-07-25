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

    // MARK: - AskUserQuestion answer directive (Open Island parity)

    /// The `AskUserQuestion` tool input Claude Code sends on the hook.
    private var questionToolInput: [String: AnyJSON] {
        [
            "questions": .array([
                .object([
                    "question": .string("Which package manager?"),
                    "header": .string("Answer needed"),
                    "options": .array([
                        .object(["label": .string("npm")]),
                        .object(["label": .string("pnpm")]),
                    ]),
                ]),
            ]),
        ]
    }

    /// Locks the exact `updatedInput` wire shape Open Island uses to answer a
    /// question: `decision.{behavior:"allow", updatedInput:<original input +
    /// answers map>}`. The original `questions` array must survive and the
    /// answers (including a freeform "Other" value) must be merged under
    /// `answers`, keyed by question text.
    func testAllowWithInputCarriesAnswers() {
        var input = questionToolInput
        input["answers"] = .object(["Which package manager?": .string("Bun (custom)")])

        let json = ApprovalDecision.allowWithInput(input).hookOutputJSON(for: approval())
        let hook = decode(json)?["hookSpecificOutput"] as? [String: Any]
        XCTAssertEqual(hook?["hookEventName"] as? String, "PermissionRequest")

        let decision = hook?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        XCTAssertNil(decision?["updatedPermissions"])

        let updatedInput = decision?["updatedInput"] as? [String: Any]
        XCTAssertNotNil(updatedInput?["questions"], "original tool input must be preserved")
        let answers = updatedInput?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["Which package manager?"] as? String, "Bun (custom)")
    }

    /// An `AskUserQuestion` permission request must NOT auto-resolve: it stays
    /// pending (driving the notch's question card) until the user answers,
    /// then the answer round-trips as an `allow` + `updatedInput`.
    func testAskUserQuestionSuspendsThenAnswers() async {
        let store = ClaudeCodeStore.shared
        let sessionID = "qtest-\(UUID().uuidString)"
        let payload = PermissionRequestPayload(
            sessionID: sessionID,
            toolName: "AskUserQuestion",
            toolInput: questionToolInput,
            toolUseID: "tu1",
            projectDirectory: "/repo",
            cwd: "/repo",
            permissionMode: nil,
            permissionSuggestions: nil
        )

        async let body = store.handlePermissionRequest(payload, rawJSON: "{}")

        // Must suspend as a pending entry, not auto-allow.
        var spins = 0
        while !store.pending.contains(where: { $0.sessionID == sessionID }) && spins < 200 {
            await Task.yield()
            spins += 1
        }
        XCTAssertTrue(
            store.pending.contains(where: { $0.sessionID == sessionID }),
            "AskUserQuestion should suspend as a pending entry, not auto-resolve"
        )

        store.answerQuestion(sessionID: sessionID, answers: ["Which package manager?": "pnpm"])
        let result = await body

        XCTAssertFalse(store.pending.contains(where: { $0.sessionID == sessionID }))
        let decision = (decode(result)?["hookSpecificOutput"] as? [String: Any])?["decision"] as? [String: Any]
        XCTAssertEqual(decision?["behavior"] as? String, "allow")
        let answers = (decision?["updatedInput"] as? [String: Any])?["answers"] as? [String: Any]
        XCTAssertEqual(answers?["Which package manager?"] as? String, "pnpm")
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
