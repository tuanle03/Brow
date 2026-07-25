import XCTest
@testable import Brow

/// TDD test for Task 2.6's cards — button label → reducer wiring, tested at
/// the `AIAppModel` level (views are visual, not unit-tested here). Each
/// case mirrors the exact call shape a card's button action makes:
/// `ApprovalCardView`'s "Allow once" button calls
/// `model.approve(sessionID:.allowOnce())`; its "Always allow <tool>"
/// button calls `model.approve(sessionID:ApprovalCardView.alwaysAllowResolution(toolName:))`;
/// `QuestionCardView`'s submit button calls `model.answer(sessionID:answers:)`.
@MainActor
final class CardActionTests: XCTestCase {
    private func ts(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    // MARK: - Approval card: "Allow once"

    func testAllowOnceClearsPermissionRequestAndResumesRunning() {
        let m = AIAppModel()
        m.ingest([
            .sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))),
            .permissionRequested(.init(
                sessionID: "s1",
                request: PermissionRequest(id: "p", title: "Run command", summary: "rm -rf build/", affectedPath: "build/", toolName: "Bash"),
                timestamp: ts(2)
            )),
        ])
        XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .waitingForApproval)

        // Mirrors ApprovalCardView's "Allow once" button action exactly.
        m.approve(sessionID: "s1", .allowOnce())

        XCTAssertNil(m.state.sessionsByID["s1"]?.permissionRequest)
        XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .running)
    }

    // MARK: - Approval card: "Always allow <tool>"

    func testAlwaysAllowBuildsAddRulesUpdateInAllowOnce() {
        let resolution = ApprovalCardView.alwaysAllowResolution(toolName: "Bash")

        guard case let .allowOnce(updatedInput, updatedPermissions) = resolution else {
            return XCTFail("expected .allowOnce, got \(resolution)")
        }
        XCTAssertNil(updatedInput)
        XCTAssertEqual(updatedPermissions.count, 1)

        guard case let .addRules(destination, rules, behavior) = updatedPermissions[0] else {
            return XCTFail("expected .addRules, got \(updatedPermissions[0])")
        }
        XCTAssertEqual(destination, .session)
        XCTAssertEqual(behavior, .allow)
        XCTAssertEqual(rules, [ClaudePermissionRuleValue(toolName: "Bash")])
    }

    func testAlwaysAllowResolutionClearsPermissionRequestAndResumesRunning() {
        let m = AIAppModel()
        m.ingest([
            .sessionStarted(.init(sessionID: "s1", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))),
            .permissionRequested(.init(
                sessionID: "s1",
                request: PermissionRequest(id: "p", title: "Run command", summary: "rm -rf build/", affectedPath: "build/", toolName: "Bash"),
                timestamp: ts(2)
            )),
        ])

        // Mirrors ApprovalCardView's "Always allow Bash" button action.
        m.approve(sessionID: "s1", ApprovalCardView.alwaysAllowResolution(toolName: "Bash"))

        XCTAssertNil(m.state.sessionsByID["s1"]?.permissionRequest)
        XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .running)
    }

    // MARK: - Question card: submit

    func testAnswerClearsQuestionPromptAndResumesRunning() {
        let m = AIAppModel()
        m.ingest([
            .sessionStarted(.init(sessionID: "s2", title: "repo", tool: .claudeCode, summary: "", timestamp: ts(1))),
            .questionAsked(.init(
                sessionID: "s2",
                prompt: QuestionPrompt(
                    title: "Which package manager?",
                    questions: [
                        QuestionPromptItem(
                            question: "Which package manager should I use?",
                            header: "Answer needed",
                            options: [QuestionOption(label: "npm"), QuestionOption(label: "pnpm")]
                        ),
                    ]
                ),
                timestamp: ts(2)
            )),
        ])
        XCTAssertEqual(m.state.sessionsByID["s2"]?.phase, .waitingForAnswer)

        // Mirrors QuestionCardView's submit button action.
        m.answer(sessionID: "s2", answers: ["Which package manager should I use?": "pnpm"])

        XCTAssertNil(m.state.sessionsByID["s2"]?.questionPrompt)
        XCTAssertEqual(m.state.sessionsByID["s2"]?.phase, .running)
    }
}
