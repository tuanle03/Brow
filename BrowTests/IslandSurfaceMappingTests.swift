import XCTest
@testable import Brow

final class IslandSurfaceMappingTests: XCTestCase {
    // MARK: - notificationSurface(for:)

    func testPermissionRequestedMapsToApprovalCard() {
        let event = AgentEvent.permissionRequested(.init(
            sessionID: "s1",
            request: PermissionRequest(id: "p1", title: "Run tool", summary: "$ ls", affectedPath: "/tmp", toolName: "Bash"),
            timestamp: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertEqual(IslandSurface.notificationSurface(for: event), .approvalCard(sessionID: "s1"))
    }

    func testQuestionAskedMapsToQuestionCard() {
        let event = AgentEvent.questionAsked(.init(
            sessionID: "s2",
            prompt: QuestionPrompt(id: "q1", title: "Pick one", questions: []),
            timestamp: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertEqual(IslandSurface.notificationSurface(for: event), .questionCard(sessionID: "s2"))
    }

    func testSessionCompletedMapsToCompletionCard() {
        let event = AgentEvent.sessionCompleted(.init(
            sessionID: "s3",
            summary: "Done",
            timestamp: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertEqual(IslandSurface.notificationSurface(for: event), .completionCard(sessionID: "s3"))
    }

    func testInterruptCompletionMapsToNil() {
        let event = AgentEvent.sessionCompleted(.init(
            sessionID: "s4",
            summary: "Interrupted",
            timestamp: Date(timeIntervalSince1970: 1000),
            isInterrupt: true
        ))
        XCTAssertNil(IslandSurface.notificationSurface(for: event))
    }

    func testNonInterruptFlagStillMapsToCompletionCard() {
        let event = AgentEvent.sessionCompleted(.init(
            sessionID: "s5",
            summary: "Done",
            timestamp: Date(timeIntervalSince1970: 1000),
            isInterrupt: false
        ))
        XCTAssertEqual(IslandSurface.notificationSurface(for: event), .completionCard(sessionID: "s5"))
    }

    func testNonNotificationEventMapsToNil() {
        let event = AgentEvent.activityUpdated(.init(
            sessionID: "s6",
            summary: "Working",
            phase: .running,
            timestamp: Date(timeIntervalSince1970: 1000)
        ))
        XCTAssertNil(IslandSurface.notificationSurface(for: event))
    }

    // MARK: - isNotificationCard

    func testIsNotificationCard() {
        XCTAssertFalse(IslandSurface.closed.isNotificationCard)
        XCTAssertFalse(IslandSurface.sessionList.isNotificationCard)
        XCTAssertTrue(IslandSurface.approvalCard(sessionID: "s1").isNotificationCard)
        XCTAssertTrue(IslandSurface.questionCard(sessionID: "s1").isNotificationCard)
        XCTAssertTrue(IslandSurface.completionCard(sessionID: "s1").isNotificationCard)
    }

    // MARK: - autoDismissesWhenPresentedAsNotification

    func testAutoDismissesWhenPresentedAsNotification() {
        XCTAssertFalse(IslandSurface.closed.autoDismissesWhenPresentedAsNotification)
        XCTAssertFalse(IslandSurface.sessionList.autoDismissesWhenPresentedAsNotification)
        XCTAssertFalse(IslandSurface.approvalCard(sessionID: "s1").autoDismissesWhenPresentedAsNotification)
        XCTAssertFalse(IslandSurface.questionCard(sessionID: "s1").autoDismissesWhenPresentedAsNotification)
        XCTAssertTrue(IslandSurface.completionCard(sessionID: "s1").autoDismissesWhenPresentedAsNotification)
    }

    // MARK: - actionableSessionID

    func testActionableSessionID() {
        XCTAssertNil(IslandSurface.closed.actionableSessionID)
        XCTAssertNil(IslandSurface.sessionList.actionableSessionID)
        XCTAssertEqual(IslandSurface.approvalCard(sessionID: "s1").actionableSessionID, "s1")
        XCTAssertEqual(IslandSurface.questionCard(sessionID: "s2").actionableSessionID, "s2")
        XCTAssertEqual(IslandSurface.completionCard(sessionID: "s3").actionableSessionID, "s3")
    }
}
