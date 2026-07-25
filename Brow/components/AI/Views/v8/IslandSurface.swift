import Foundation

/// Which notch surface is currently on screen. Pure state — no side effects,
/// no view code — so routing logic is unit-testable without SwiftUI.
///
/// Ported from the reference's `IslandSurface` (`docs/notch-surface-model.md`
/// + `AppModel.notificationSurface(for:)`), but expanded from the
/// reference's single `sessionList(actionableSessionID:)` case into the
/// distinct card cases the brief specifies — `closed`/`sessionList` are
/// plain layout states; `approvalCard`/`questionCard`/`completionCard` are
/// the auto-expanded notification surfaces per session.
enum IslandSurface: Equatable {
    case closed
    case sessionList
    case approvalCard(sessionID: String)
    case questionCard(sessionID: String)
    case completionCard(sessionID: String)

    /// Routes an `AgentEvent` to the notification surface it should open,
    /// or `nil` if the event doesn't pop a surface.
    ///
    /// - `permissionRequested` → `.approvalCard`
    /// - `questionAsked` → `.questionCard`
    /// - `sessionCompleted` → `.completionCard`, unless `isInterrupt == true`
    ///   (an interrupted turn isn't a finished task — no completion card).
    /// - everything else → `nil`.
    static func notificationSurface(for event: AgentEvent) -> IslandSurface? {
        switch event {
        case let .permissionRequested(payload):
            .approvalCard(sessionID: payload.sessionID)
        case let .questionAsked(payload):
            .questionCard(sessionID: payload.sessionID)
        case let .sessionCompleted(payload):
            payload.isInterrupt == true ? nil : .completionCard(sessionID: payload.sessionID)
        default:
            nil
        }
    }

    /// True for the three auto-expanded notification cards; false for the
    /// plain layout states (`closed`, `sessionList`).
    var isNotificationCard: Bool {
        switch self {
        case .closed, .sessionList:
            false
        case .approvalCard, .questionCard, .completionCard:
            true
        }
    }

    /// Ported from the reference's rule exactly: a completion card
    /// auto-dismisses (nothing more for the user to do); approval and
    /// question cards stay open until the user resolves them.
    var autoDismissesWhenPresentedAsNotification: Bool {
        switch self {
        case .completionCard:
            true
        case .closed, .sessionList, .approvalCard, .questionCard:
            false
        }
    }

    /// The session a card surface belongs to; `nil` for the non-card states.
    var actionableSessionID: String? {
        switch self {
        case .closed, .sessionList:
            nil
        case let .approvalCard(sessionID), let .questionCard(sessionID), let .completionCard(sessionID):
            sessionID
        }
    }
}
