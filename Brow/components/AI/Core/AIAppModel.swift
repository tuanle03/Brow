import Foundation
import Observation

/// The `@Observable` owner of the ported `SessionState` reducer.
///
/// ADDITIVE, non-destructive by design (Task 1.7): this runs as a pure state
/// mirror in *parallel* with `ClaudeCodeStore`, which keeps owning the live
/// approval queue, the `withCheckedContinuation` HTTP-response registry, and
/// the current UI — none of that moves here yet. `ingest`/`approve`/`answer`
/// below only fold into `state` via `SessionState`'s reducer; they have no
/// side effects (no HTTP responses, no continuation resolution). The atomic
/// switchover — UI reads `AIAppModel`, the continuation registry moves here,
/// `ClaudeCodeStore` becomes a thin shim — is Task 1.8, not this one.
@MainActor
@Observable
final class AIAppModel {
    static let shared = AIAppModel()

    var state = SessionState()

    /// Kept explicit (not relying on the implicit memberwise init) so both
    /// tests and the `shared` singleton construct the same way.
    init() {}

    /// Folds each mapped event into `state` via the pure reducer.
    func ingest(_ events: [AgentEvent]) {
        for event in events {
            state.apply(event)
        }
    }

    /// Updates the reducer only. Does NOT complete any bridge HTTP
    /// continuation — `ClaudeCodeStore` still owns that registry until Task
    /// 1.8's switchover.
    func approve(sessionID: String, _ resolution: PermissionResolution) {
        state.resolvePermission(sessionID: sessionID, resolution, at: Date())
    }

    /// Updates the reducer only. Does NOT complete any bridge HTTP
    /// continuation — `ClaudeCodeStore` still owns that registry until Task
    /// 1.8's switchover.
    func answer(sessionID: String, answers: [String: String]) {
        state.answerQuestion(sessionID: sessionID, answers: answers, at: Date())
    }
}
