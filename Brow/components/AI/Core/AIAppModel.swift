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

    // MARK: - Task 2.9: completion-card driver

    /// Session id → the `updatedAt` at which its completion card was last
    /// dismissed. A session re-completing with a newer `updatedAt` shows its
    /// card again — matching the old per-`Stop` toast, which fired a fresh
    /// notification on every completion of the same session.
    private(set) var dismissedCompletions: [String: Date] = [:]

    /// The session whose completion card should show right now: the
    /// most-recently-completed visible session that isn't stale and whose
    /// latest completion hasn't been dismissed. Replaces the old coupling to
    /// `ClaudeCodeStore.transientNotification`'s `.stopped` toast. `now` is a
    /// parameter (not read internally) to stay wall-clock-free/testable.
    func completionCardSession(now: Date) -> AgentSession? {
        state.sessionsByID.values
            .filter { $0.isVisibleInIsland && $0.phase == .completed }
            .filter { !$0.isStaleCompleted(now: now) }
            .filter { session in
                guard let dismissedAt = dismissedCompletions[session.id] else { return true }
                return session.updatedAt > dismissedAt
            }
            .max(by: { $0.updatedAt < $1.updatedAt })
    }

    /// Marks this session's current completion as seen so its card stops
    /// showing (called by the auto-dismiss timer or a manual dismiss).
    /// Idempotent; a later completion with a newer `updatedAt` re-shows.
    func dismissCompletion(_ session: AgentSession) {
        dismissedCompletions[session.id] = session.updatedAt
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

    // MARK: - Task 2.5: session list ranking / grouping / staleness

    /// Reference's `islandActivityThreshold` — how recently a session must
    /// have updated to still count as "active" for scoring purposes, even
    /// past the running/attention phases.
    private static let islandActivityThreshold: TimeInterval = 20 * 60

    /// Reference's `completedStaleThreshold` (a user preference there; a
    /// fixed constant here — Brow has no appearance-preferences surface for
    /// it yet). Matches `AgentSession.isStaleCompleted`'s own default.
    private static let completedStaleThreshold: TimeInterval = AgentSession.staleCompletedThreshold

    /// Ranking score for the session list — ported verbatim (same weights)
    /// from the reference's `AppModel.displayPriority(for:now:)`. Higher
    /// sorts first. Pure: every time-dependent branch reads `now`, never
    /// `Date()`.
    ///
    /// Dropped vs. the reference: `isSubagentSession` (no subagent concept
    /// in Brow's trimmed `ClaudeSessionMetadata`) and the `monitoring.
    /// liveAttachmentKey` live-attachment dedup (no such registry in Brow) —
    /// neither factors into the score itself, both only filtered the
    /// reference's primary/overflow bucket split, which Brow doesn't have.
    func displayPriority(for session: AgentSession, now: Date) -> Int {
        var score = 0

        // Reference's `islandPresence(at:)` collapsed to the one thing
        // `displayPriority` actually branches on: is this session "active"
        // (running, needs attention, or updated within the activity
        // window) vs. merely alive-but-idle.
        let isActivePresence = session.phase == .running
            || session.phase.requiresAttention
            || now.timeIntervalSince(session.updatedAt) <= Self.islandActivityThreshold

        if session.isProcessAlive {
            score += isActivePresence ? 12_000 : 3_000
        } else if session.origin == .demo || session.phase.requiresAttention {
            score += 6_000
        }

        if session.phase.requiresAttention {
            score += 10_000
        }

        if session.currentToolName?.isEmpty == false {
            score += 6_000
        }

        if session.jumpTarget != nil {
            score += 4_000
        }

        switch session.phase {
        case .running:
            score += 2_000
        case .waitingForApproval:
            score += 1_500
        case .waitingForAnswer:
            score += 1_200
        case .completed:
            score += 600
        }

        if session.isStaleCompleted(now: now, threshold: Self.completedStaleThreshold) {
            score -= 900
        }

        let age = now.timeIntervalSince(session.updatedAt)
        switch age {
        case ..<120:
            score += 500
        case ..<900:
            score += 250
        case ..<3_600:
            score += 120
        case ..<21_600:
            score += 40
        default:
            break
        }

        return score
    }

    /// Visible sessions (`isVisibleInIsland`), ranked by `displayPriority`
    /// descending. `now` is a parameter (not read internally) so this stays
    /// unit-testable without wall-clock flakiness — mirrors the reference's
    /// `surfacedSessions`/`computeSessionBuckets().primary`.
    func surfacedSessions(now: Date) -> [AgentSession] {
        state.sessionsByID.values
            .filter(\.isVisibleInIsland)
            .sorted { lhs, rhs in
                let lhsScore = displayPriority(for: lhs, now: now)
                let rhsScore = displayPriority(for: rhs, now: now)
                if lhsScore != rhsScore { return lhsScore > rhsScore }
                if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
    }

    /// `islandSessionSections(group:sort:now:)` grouping into titled
    /// sections, ready for `SessionListView`. Ported from the reference's
    /// `islandSessionSections` — same four grouping modes, same
    /// state-bucket ordering (approval → answer → running → done → idle).
    func islandSessionSections(group: IslandSessionGroup, sort: IslandSessionSort, now: Date) -> [IslandSessionSection] {
        let sessions = sortIslandSessions(surfacedSessions(now: now), sort: sort)

        switch group {
        case .none:
            return [IslandSessionSection(id: "all", title: "Sessions", sessions: sessions)]
        case .state:
            return stateGroupedSections(for: sessions, now: now)
        case .agent:
            return AgentTool.allCases.compactMap { tool in
                let list = sessions.filter { $0.tool == tool }
                guard !list.isEmpty else { return nil }
                return IslandSessionSection(id: "agent-\(tool.rawValue)", title: tool.displayName, sessions: list)
            }
        case .project:
            let names = Set(sessions.map(Self.projectGroupName(for:))).sorted {
                $0.localizedStandardCompare($1) == .orderedAscending
            }
            return names.compactMap { name in
                let list = sessions.filter { Self.projectGroupName(for: $0) == name }
                guard !list.isEmpty else { return nil }
                return IslandSessionSection(id: "project-\(name)", title: name, sessions: list)
            }
        }
    }

    private func sortIslandSessions(_ sessions: [AgentSession], sort: IslandSessionSort) -> [AgentSession] {
        switch sort {
        case .attention:
            // Already ranked by displayPriority via surfacedSessions(now:).
            return sessions
        case .lastUpdate:
            return sessions.sorted { lhs, rhs in
                if lhs.updatedAt == rhs.updatedAt {
                    return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
                }
                return lhs.updatedAt > rhs.updatedAt
            }
        }
    }

    private func stateGroupedSections(for sessions: [AgentSession], now: Date) -> [IslandSessionSection] {
        let definitions: [(id: String, title: String, include: (AgentSession) -> Bool)] = [
            ("approval", "Needs approval", { $0.phase == .waitingForApproval }),
            ("answer", "Needs answer", { $0.phase == .waitingForAnswer }),
            ("running", "In progress", { $0.phase == .running }),
            ("done", "Just done", { session in
                session.phase == .completed
                    && !session.isStaleCompleted(now: now, threshold: Self.completedStaleThreshold)
            }),
            ("idle", "Idle", { session in
                session.phase == .completed
                    && session.isStaleCompleted(now: now, threshold: Self.completedStaleThreshold)
            }),
        ]

        return definitions.compactMap { definition in
            let list = sessions.filter(definition.include)
            guard !list.isEmpty else { return nil }
            return IslandSessionSection(id: "state-\(definition.id)", title: definition.title, sessions: list)
        }
    }

    private static func projectGroupName(for session: AgentSession) -> String {
        if let workspace = session.jumpTarget?.workspaceName.trimmingCharacters(in: .whitespacesAndNewlines),
           !workspace.isEmpty {
            return workspace
        }

        let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return session.tool.displayName }

        let pieces = title.split(separator: "·", maxSplits: 1).map {
            String($0).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return pieces.last?.isEmpty == false ? pieces.last! : title
    }
}

// MARK: - Task 2.5: grouping / sort / section types

/// How `islandSessionSections` buckets the ranked session list.
enum IslandSessionGroup: Equatable {
    case none, state, agent, project
}

/// How sessions are ordered within (and across, for `.none`) sections.
enum IslandSessionSort: Equatable {
    /// Reference-ranked order — `displayPriority` descending, already the
    /// order `surfacedSessions(now:)` returns.
    case attention
    /// Most-recently-updated first.
    case lastUpdate
}

/// One titled group of sessions in the list — the shape `SessionListView`
/// renders.
struct IslandSessionSection: Identifiable, Equatable {
    var id: String
    var title: String
    var sessions: [AgentSession]
}
