# Brow ⟶ Open Island Parity — Design Spec

**Date:** 2026-07-25
**Status:** Draft for review (no implementation started)
**Reference project:** `Octane0411/open-vibe-island` ("Open Island"), studied at commit of 2026-07-25.

---

## 1. Goal

Bring Brow's AI / "vibecode" experience to feature parity with Open Island's **core
experience**, adopting Open Island's full v8 visual design, while keeping Brow's
existing Music, Mascot, Battery/Calendar/Brightness/Volume/Webcam features as
first-class citizens of the same notch.

The AI experience today works but is a single-agent, sandbox-limited, toast-based
implementation. The target is Open Island's polished, multi-surface, process-aware,
jump-back-capable experience — rendered in Open Island's v8 "the pill is the product"
visual language, cohesive with Brow's other features.

### Locked decisions (from stakeholder)

| Decision | Choice | Consequence |
|---|---|---|
| **Scope** | **Core experience parity** | Claude Code + Codex (CLI) as wired agents. Notification/session/approval UX fully redesigned. Long tail deferred (see Non-Goals). |
| **Sandbox** | **Drop the App Sandbox** | Enables `ps`/`lsof` process discovery, AppleScript terminal jump-back, and an installed hook binary. Distribution becomes a notarized DMG (no Mac App Store). Adds Automation/Accessibility TCC prompts. |
| **Visual** | **Full v8 adoption** | ink `#0D0D0F` / paper `#F1EAD9` palette, shape-shifting notification pill, `UnifiedBars` glyph, dedicated approval/question/completion surfaces. Music & Mascot re-fitted into this chrome. |
| **Delivery** | **Review written plan first** | This spec + the phased implementation plan are committed for review before any code changes. |

## 2. Non-Goals (explicitly deferred, not part of this migration)

These are real Open Island features intentionally **out of scope** for Core parity.
Each is designed so it can be added later without rework (see §6 extension points).

- **Agents beyond Claude Code + Codex CLI**: Cursor, Gemini CLI, OpenCode, Kimi,
  Qoder/Qwen/Factory/CodeBuddy (Claude forks). The data model and hook layer are
  built to accept them; adapters are simply not written yet.
- **Codex Desktop app-server** (JSON-RPC live observation + `codex://` deep-link).
  Codex **CLI** hooks are in scope; the desktop app-server is not.
- **Apple Watch + iPhone companions** and their HTTP/SSE/Bonjour bridge.
- **Warp precision jump** (SQLite group-container reads + AX menu-click) and the full
  **JetBrains** family jump. Terminal jump-back covers a curated subset (§5.4).
- **Usage dashboards** (Claude/Codex 5h & 7d rate limits). Deferred; the header has a
  reserved slot for it.
- **i18n** (Simplified Chinese). English only for now; strings routed through a single
  table so localization is a later drop-in.

## 3. Architecture Overview

### 3.1 Build & module layout

Brow stays an **Xcode project** (no full SwiftPM conversion). We add executable targets
and reorganize the AI code into a clean, agent-agnostic core.

Targets after migration:

| Target | Kind | Role |
|---|---|---|
| `Brow` | app | Unchanged shell; hosts the new AI core + v8 UI. **Sandbox entitlement removed.** |
| `BrowXPCHelper` | xpc-service | Unchanged (brightness/accessibility helper). |
| **`BrowAgentHook`** | command-line tool (**new**) | The installed hook binary agents invoke. Reads stdin, enriches with runtime context (terminal app, TTY, session id), does a blocking loopback POST to the in-app bridge, writes the directive to stdout. Fail-open (always exits 0). Copied into the app bundle and installed to `~/Library/Application Support/Brow/bin/BrowAgentHook`. |
| **`BrowAgentSetup`** | command-line tool (**new**, optional) | Dev/CLI installer mirroring the in-app installer, for scripted install/uninstall/status. Nice-to-have; can be dropped if time-constrained. |

> **Transport decision (recommendation, open to change in review).** Open Island uses a
> raw Unix-domain-socket + NDJSON `BridgeServer` (~2700 lines). Brow already has a
> working loopback-HTTP bridge (`ClaudeCodeBridge`, `NWListener` + a hand-written HTTP
> parser) that **already blocks the hook until the user decides** (via
> `withCheckedContinuation`). We **keep the loopback-HTTP transport** and generalize it,
> rather than rewrite to Unix sockets. The only change to the hook mechanism is replacing
> the *inline curl* with the installed **`BrowAgentHook`** binary, which can enrich the
> payload with terminal/TTY/session context (impossible from inline curl) before the
> blocking POST. This gets us Open Island's enrichment + multi-agent `--source` behavior
> for a fraction of the transport rewrite. Rationale: refactor where it pays, reuse what
> already works.

### 3.2 State model — adopt Open Island's core

Replace `ClaudeCodeStore`'s ad-hoc queue with Open Island's clean, testable model,
ported and trimmed to Claude + Codex:

- **`AgentTool`** — enum of wired agents (`claudeCode`, `codex`) with `displayName`,
  `shortName`, `brandColorHex`, `isClaudeCodeFork`. (Enum kept open for later agents.)
- **`SessionPhase`** — `running | waitingForApproval | waitingForAnswer | completed`.
  `requiresAttention` = the two `waiting*` cases.
- **`SessionAttachmentState`** — `attached | stale | detached`.
- **`JumpTarget`** — `terminalApp, workspaceName, paneTitle, workingDirectory?,`
  `terminalSessionID?, terminalTTY?, tmuxTarget?, tmuxSocketPath?, codexThreadID?`.
- **`PermissionRequest` / `QuestionPrompt` / `QuestionPromptItem` / `QuestionOption`** —
  including `suggestedUpdates` (Claude "always allow") and freeform question options.
- **`PermissionResolution`** — `allowOnce(updatedInput?, updatedPermissions) | deny(message?, interrupt)`.
- **`AgentSession`** — the canonical record (`id, title, tool, phase, attachmentState,`
  `summary, updatedAt, firstSeenAt, permissionRequest?, questionPrompt?, jumpTarget?,`
  `isRemote, isHookManaged, isSessionEnded, isProcessAlive, processNotSeenCount`, plus
  `claudeMetadata?/codexMetadata?`). `isVisibleInIsland` computed rule ported.
- **`AgentEvent`** — Codable, `type`-discriminated enum: `sessionStarted`,
  `activityUpdated`, `permissionRequested`, `questionAsked`, `sessionCompleted`,
  `jumpTargetUpdated`, `sessionMetadataUpdated`, `actionableStateResolved` (Claude/Codex
  subset of Open Island's 12 cases).
- **`SessionState`** — `[String: AgentSession]` with a **pure `apply(_ event:)` reducer**
  as the single source of truth, plus `resolvePermission`, `answerQuestion`,
  `reconcileAttachmentStates`, `markProcessLiveness` (2-miss debounce),
  `removeInvisibleSessions`.

**Observation:** the new AI core uses Swift's **`@Observable`** (matching Open Island and
enabling per-property SwiftUI tracking), even though the rest of Brow uses Combine
`ObservableObject`. The two interoperate fine. The central owner is a new **`AIAppModel`**
(`@MainActor @Observable`) that owns `state: SessionState`, the bridge, and the
coordinators — analogous to Open Island's `AppModel` but scoped to the AI subsystem and
composed into Brow's existing `BrowViewCoordinator`.

### 3.3 What is reused / refactored / replaced / new

**Reused as-is:** notch window infra (`BrowSkyLightWindow`, `NotchSpaceManager`/`CGSSpace`,
per-screen `BrowViewModel`, `NotchShape`), Music/Battery/Calendar/Brightness/Volume/Webcam
managers, `LottieView`, `KeyboardShortcuts` wiring, Sparkle.

**Refactored:** `ClaudeCodeBridge` → generalized `AgentBridge` (multi-source POST
endpoint, Claude + Codex decoders). `ClaudeCodeStore` → decomposed into `SessionState`
reducer + `AIAppModel` + coordinators. `AITaskRegistry` → folded into `AIAppModel`'s
derived/computed presentation state. `ContentView` AI-auto-expansion + halo → driven by
the new surface state machine. `ClaudeCodeHookInstaller` → `AgentHookInstaller` protocol
with `ClaudeHookInstaller` + `CodexHookInstaller` conformers, now installing the
`BrowAgentHook` binary command instead of inline curl.

**Replaced (deleted):** `AISessionsTabView.swift` (dead), `AIPanelMockup.swift`
(disconnected mock). The v8 UI supersedes `AIPanel`/`AIMonitorSection`/`AIApproveSection`/
`AIAskSection`, which are rebuilt.

**New:** `BrowAgentHook` + `BrowAgentSetup` targets; the v8 notch-surface UI
(pill + session list + approval/question/completion cards + `UnifiedBars`); process
monitoring + terminal jump-back + transcript discovery subsystems (newly possible without
the sandbox); Codex hook decoder/installer.

## 4. Subsystem Designs

### 4.1 Transport & hooks

- **`AgentBridge`** (in-app, loopback HTTP on port 21064, reusing Brow's `NWListener` +
  parser). Endpoint `POST /event` accepts an enriched envelope carrying `source`
  (`claude`/`codex`), the raw hook payload, and runtime context. For interactive events
  (`PermissionRequest`, `AskUserQuestion`) it suspends the HTTP response via
  `withCheckedContinuation` (as Brow does today) until `AIAppModel` resolves it, then
  returns the agent-native directive JSON. `GET /healthz` retained.
- **`BrowAgentHook`** binary: reads stdin, parses `--source`, enriches with terminal
  app/TTY/session id (env + `osascript` probes), POSTs to the bridge with a long timeout
  for interactive events (24h for Claude `PermissionRequest`, matching Open Island;
  Codex 3600s), writes stdout directive, always exits 0.
- **Installers**: `ClaudeHookInstaller` writes `~/.claude/settings.json`;
  `CodexHookInstaller` writes `~/.codex/config.toml` (`[features] hooks=true`) +
  `~/.codex/hooks.json`. Both: install the `BrowAgentHook` command, back up before
  mutating, idempotent merge preserving other tools' hooks, install manifest for precise
  uninstall, tri-state install intent (`untouched|installed|uninstalled`) so we never
  silently reinstall what the user removed. Managed-binary copy to
  `~/Library/Application Support/Brow/bin/` with byte-compare `updateIfNeeded`.
- **Hook directive stdout shapes** (ported verbatim, they are the agent contract):
  Claude `{"continue":true,"suppressOutput":true,"hookSpecificOutput":{...decision...}}`;
  Codex `{"continue":true,"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{...}}}`.

### 4.2 Session discovery & process monitoring (unlocked by dropping the sandbox)

- **Transcript discovery** (`ClaudeTranscriptDiscovery`, `CodexRolloutDiscovery`):
  scan `~/.claude/projects/**/*.jsonl` and `~/.codex/sessions/**/rollout-*.jsonl`,
  last-24h, streamed in chunks (avoid OOM), to rebuild sessions on launch and after
  missed hook events. Codex rollouts get incremental tailing.
- **Process monitoring** (`ProcessMonitoringCoordinator` + `ActiveAgentProcessDiscovery`):
  `ps -Ao pid,ppid,tty,command` + `lsof` to find live agent processes, map to sessions
  (session id → transcript path → TTY+CWD cascade), and walk the **parent-PID chain** to
  the owning terminal app (with a tmux-aware fallback). Adaptive poll cadence (2s / 60s /
  300s). 2-consecutive-miss eviction. Synthesizes sessions for agents already running
  before Brow launched.
- **Registries + persistence**: small JSON files under `~/Library/Application Support/Brow/`
  so sessions survive app restarts.

### 4.3 Notification surface state machine

Adopt Open Island's notch surface model exactly:

```
closed  ──hover/click──▶  opened + sessionList
   ▲                          │
   │   permissionRequested ──▶ opened + approvalCard   (auto)
   │   questionAsked       ──▶ opened + questionCard    (auto)
   │   sessionCompleted    ──▶ opened + completionCard  (auto)
   └── auto-collapse (10s idle / pointer-leave / resolve)
```

- Auto-expanding cards auto-collapse after ~10s idle or on pointer-leave-after-hover, and
  do **not** render as inline actions inside the session list.
- **Suppress-if-frontmost**: if the terminal that fired the event is already the user's
  frontmost window, suppress the notification (don't interrupt someone already looking).
- **Notification sound** on present (configurable system sound, default Bottle, mute
  toggle) — Brow already has `AISoundEffects`; align defaults with Open Island.
- Presentation is driven by a pure `notificationSurface(for: event)` mapping, gated by
  eligibility (notch closed or already showing a notification), same as Open Island.

### 4.4 Terminal jump-back (curated subset)

`JumpTarget` + a `TerminalJumpService` dispatching by bundle id. **In scope:**
Terminal.app, iTerm2, Ghostty (AppleScript session/TTY targeting), tmux
(`switch-client`/`select-window`/`select-pane`), VS Code / Cursor / Windsurf (`code -r`/
`cursor -r`). A `TerminalJumpTargetResolver` periodically re-derives/corrects the stored
`JumpTarget` from live terminal enumeration. **Deferred:** Warp SQLite precision jump,
JetBrains family, cmux/Kaku/WezTerm/Zellij.

### 4.5 Approval / question / completion cards (v8)

- **Approval card**: command/target preview + **Deny** / **Allow once** / **Always allow
  \<tool\>** buttons (`IslandActionButtonStyle` kinds: secondary/warning/primary). Maps to
  `PermissionResolution`. Claude `suggestedUpdates` power the "Always allow" rules. Global
  shortcuts (⌘↵ allow, ⌘⇧↵ allow-always, ⌘⎋ deny) preserved from Brow.
- **Question card** (**closes a real Brow gap**): interactive `StructuredQuestionPromptView`
  — per-question option list + freeform field. Because we control `BrowAgentHook`, the
  answer round-trips back as a hook directive (for Claude's `AskUserQuestion` we return
  the selected/typed answer via the blocked hook connection instead of Brow's current
  "auto-allow + go-to-terminal" toast).
- **Completion card**: markdown-rendered summary (needs a markdown renderer — add
  `swift-markdown-ui`, matching Open Island) + optional reply field (`TerminalTextSender`
  via tmux `send-keys` / Ghostty AppleScript — in scope only for the jump-back terminals).

### 4.6 Session list, grouping, staleness

Ported: ranked `displayPriority` scoring (attention/live/running/recency/stale), grouping
(none/state/agent/project), sort (attention/lastUpdate), stale-completed dimming +
"Idle" folding with a configurable threshold. Row = state indicator + headline
(workspace+branch+prompt) + agent chip + age + detail chevron; **row body tap jumps to
terminal**, chevron toggles detail (Open Island's "jump-first, spatial-split" rule).

### 4.7 v8 visual system

- **Palette**: `V6Palette.ink #0D0D0F` / `paper #F1EAD9`; status colors (running blue
  `#6EA7FF`, approval `#F4A4A4`, answer `#FFD58A`, completed `#6FB982`, waiting amber
  `#E7A762`); agent brand colors (claude `#d97742`, codex `#4aa3df`). **Brow's whole notch
  chrome unifies to this palette**, so Music/Mascot/Home read as the same product.
- **Shapes**: reuse Brow's `NotchShape` (it already has the concave-top + animatable
  corner radii). Adopt the fixed-window + SwiftUI-opacity/scale + `Shape.animatableData`
  corner-radius morph approach (Brow already animates the notch this way; align springs to
  Open Island's `open = spring(0.42,0.8)`, `close = smooth(0.3)` — Brow's open spring
  already matches).
- **`UnifiedBars` glyph**: port the `CAKeyframeAnimation`-on-`CAShapeLayer` glyph
  (running = staggered vertical wave, waiting = opacity pulse, idle = static) as the
  closed-pill AI indicator.

### 4.8 Music & Mascot integration (first-class, not add-on)

This is the synthesis that keeps Brow's identity. The notch is shared:

- **Closed pill content precedence** (single source of truth, replacing the current
  ad-hoc `if/else` chain): `AI-attention` (approval/question/completion pending) >
  `AI-running` (`UnifiedBars` running glyph) > `Music playing` (`MusicLiveActivity`) >
  `Mascot idle` (`MinimalFaceFeatures`/`BrowMascot`) > empty. AI attention always wins so
  a permission prompt is never hidden behind music.
- **Opened notch**: tabs remain (`AI` / `Home` / `Shelf`). The **AI tab** renders the v8
  session surface. The v8 **notification cards** (approval/question/completion)
  auto-present over *any* tab (they're a surface, not a tab), then auto-collapse back to
  the prior tab — reusing Brow's existing "remember prior tab" auto-expand machinery.
- **Mascot as agent-state expression**: `BrowMascot` states map to `SessionPhase`
  (`.working`←running, `.attention`←waiting*, `.approved`/`.denied`←resolution,
  `.idle`←no session). The mascot becomes the *emotional layer* of the agent experience
  rather than a separate widget. The idle `MinimalFaceFeatures` remains for the
  no-activity closed pill.
- **Music** keeps its `matchedGeometryEffect` album-art morph and Home-tab player,
  restyled to the ink/paper palette. Music live-activity and AI live-activity share the
  closed pill via the precedence rule above (they no longer both silently compete).

## 5. Sandbox removal

- Remove `com.apple.security.app-sandbox` from `Brow.entitlements`. Add
  `com.apple.security.automation.apple-events` (+ per-target `NSAppleEventsUsageDescription`)
  and rely on Accessibility TCC for terminal automation. Keep hardened runtime for
  notarization.
- **Distribution** shifts to a **notarized DMG via Sparkle** (Brow already uses Sparkle +
  an appcast). No Mac App Store. Update `updater/appcast.xml` flow accordingly.
- The `BrowAgentHook` binary can now be installed to and executed from
  `~/Library/Application Support/Brow/bin/` (blocked under sandbox).
- **Security note:** dropping the sandbox widens the app's capabilities. We keep the
  privilege-separated `BrowXPCHelper` and add no new network exposure (bridge stays bound
  to `127.0.0.1`). First-run Automation/Accessibility prompts are surfaced in onboarding.

## 6. Extension points (so deferred work stays cheap later)

- `AgentTool` enum + `AgentHookInstaller` protocol + per-source decoders → adding Cursor/
  Gemini/OpenCode/Kimi is a new decoder + installer, no core change.
- `AgentEvent`/`SessionState.apply` already model the events other agents need.
- `TerminalJumpService` bundle-id registry → new terminals are new registry entries.
- Header has a reserved slot for usage; `WatchNotificationRelay` seam is left as a TODO
  boundary on `AIAppModel`'s event stream.

## 7. Cleanup included in this migration

- Delete `AISessionsTabView.swift` (dead, 203 lines).
- Delete `AIPanelMockup.swift` (disconnected mock, 536 lines) — replace with SwiftUI
  `#Preview`s using the debug-scenario snapshots (Open Island's `IslandDebugScenario`
  pattern) so previews stay live-model-backed.
- Remove the unused `Pow` dependency if still unused after the rebuild.

## 8. Risks & open questions

1. **Transport choice** (§3.1) — recommendation is keep loopback-HTTP + installed binary.
   If the reviewer prefers exact Open Island fidelity, we switch to Unix-socket + NDJSON
   `BridgeServer` (larger, but 1:1 with the reference). *Decision needed at review.*
2. **AskUserQuestion round-trip for Claude Code** — returning a typed answer via the hook
   directive depends on Claude Code's hook contract accepting an answer payload for
   `AskUserQuestion`. If the contract can't carry a freeform answer back, we fall back to
   Brow's current behavior for that one case and document it. *Verify against Claude Code
   hook docs during Phase 2.*
3. **Notarization / signing identity** — dropping the sandbox + DMG distribution needs a
   Developer ID identity and notarization in CI. Confirm the signing setup exists.
4. **Multi-screen** — Brow is genuinely multi-display (per-screen `BrowViewModel`); Open
   Island's surface logic is largely single-overlay. The surface state machine must be
   reconciled with Brow's per-screen windows (surfaces present on the active screen).
5. **`@Observable` vs Combine boundary** — mixing is supported but needs care where new
   AI `@Observable` state feeds existing Combine views; wrap at `BrowViewCoordinator`.

## 9. Phasing (high-level; detailed steps in the implementation plan)

0. **Sandbox + targets groundwork** — remove sandbox, add `BrowAgentHook` target + managed
   install, notarized-DMG path. Prove the installed binary round-trips one Claude event.
1. **Agent core** — port `AgentSession`/`AgentEvent`/`SessionState` reducer + `AIAppModel`;
   migrate Claude ingestion onto it behind the existing UI (no visual change yet). Tests
   on the reducer.
2. **v8 visual + surface state machine** — rebuild the notch chrome, closed pill,
   `UnifiedBars`, session list, and the approval/question/completion surfaces in the v8
   palette. Integrate Music/Mascot precedence. Interactive question answering.
3. **Codex CLI** — decoder + installer + rollout discovery, onto the same core/UI.
4. **Process monitoring + terminal jump-back** — `ps`/`lsof` liveness, transcript
   discovery, jump-back for the curated terminal subset, `JumpTarget` resolver.
5. **Polish + cleanup** — sounds, staleness/grouping/sort settings, dead-code removal,
   onboarding for the new permissions, verification pass.

## 10. Verification approach

- Unit tests on the `SessionState.apply` reducer (pure function — highest-value tests).
- Reducer/hook decode round-trip tests for Claude + Codex payload fixtures.
- A debug-scenario harness (port Open Island's `IslandDebugScenario`) to drive each
  surface (closed/sessionList/approval/question/completion) from mock state for visual QA
  and `#Preview`s.
- End-to-end manual: real Claude Code + Codex sessions exercising approve/deny/answer/
  jump-back, per the `/verify` flow, before each phase is called done.
