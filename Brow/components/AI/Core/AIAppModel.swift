import Foundation
import Observation

/// Task 2.4: what the single closed-pill slot shows when AI, Music, and
/// Mascot all want it. `sessionID` (not the whole `AgentSession`) keeps
/// this `Equatable` trivially — callers look the session back up in
/// `AIAppModel.state.sessionsByID` to render it.
enum ClosedPillContent: Equatable {
    case aiAttention(sessionID: String)
    case aiRunning
    case music
    case mascot
    case empty
}

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

    /// Task 2.2: the closed-pill glyph's mode, aggregated over sessions
    /// visible in the island (`AgentSession.isVisibleInIsland`). Pure —
    /// reads only `state`. Precedence: a session needing approval/answer
    /// always wins (`.waiting`); otherwise any actively running session
    /// wins (`.running`); otherwise `.idle`.
    var islandClosedMode: UnifiedBarsGlyph.Mode {
        let visible = state.sessionsByID.values.filter(\.isVisibleInIsland)
        if visible.contains(where: { $0.phase.requiresAttention }) { return .waiting }
        if visible.contains(where: { $0.phase == .running }) { return .running }
        return .idle
    }

    /// Pure precedence resolver for the closed pill (Task 2.4). Takes
    /// music/mascot availability as parameters instead of reading
    /// `MusicManager`/`Defaults` directly, so this stays unit-testable
    /// without AppKit or user defaults.
    ///
    /// Precedence, highest first:
    /// 1. Any visible session (`isVisibleInIsland`) whose phase
    ///    `requiresAttention` → `.aiAttention`. Always wins, even over a
    ///    currently-playing song — a permission/question prompt must never
    ///    hide behind the music visualizer. Tiebreak when more than one
    ///    session needs attention: the most recently updated one
    ///    (`updatedAt` desc) — the thing that just fired.
    /// 2. Else, any visible session actively `.running` (mirrors
    ///    `islandClosedMode == .running`) → `.aiRunning`.
    /// 3. Else, `musicPlaying` → `.music`.
    /// 4. Else, `mascotEnabled` → `.mascot`.
    /// 5. Else → `.empty`.
    func closedPillContent(musicPlaying: Bool, mascotEnabled: Bool) -> ClosedPillContent {
        let visible = state.sessionsByID.values.filter(\.isVisibleInIsland)

        if let mostRecent = visible
            .filter(\.phase.requiresAttention)
            .max(by: { $0.updatedAt < $1.updatedAt }) {
            return .aiAttention(sessionID: mostRecent.id)
        }
        if islandClosedMode == .running { return .aiRunning }
        if musicPlaying { return .music }
        if mascotEnabled { return .mascot }
        return .empty
    }
}
