import Foundation

/// Where an agent session currently sits in its lifecycle.
enum SessionPhase: String, Codable, Sendable, Equatable {
    case running, waitingForApproval, waitingForAnswer, completed

    /// The two phases that should pull the notch open and hold the user's
    /// eye — everything else can sit quietly in the session list.
    var requiresAttention: Bool { self == .waitingForApproval || self == .waitingForAnswer }

    var displayName: String {
        switch self {
        case .running: "Running"
        case .waitingForApproval: "Needs approval"
        case .waitingForAnswer: "Needs answer"
        case .completed: "Completed"
        }
    }
}

/// Whether Brow still has a live line on a session (hook connection /
/// process liveness) versus reconstructing it from a stale transcript scan.
enum SessionAttachmentState: String, Codable, Sendable, Equatable {
    case attached, stale, detached

    var isLive: Bool { self == .attached }
}
