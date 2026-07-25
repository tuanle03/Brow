# Open Island Parity — Phase 2 (v8 UI + Music/Mascot + switchover) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Rebuild Brow's AI notch experience in Open Island's v8 "pill is the product" visual language — closed pill, shape-shifting notification surfaces (approval/question/completion), session list — driven by the ported `AIAppModel`/`SessionState` core, with Music and Mascot folded in as first-class citizens of the same ink/paper chrome. Complete the engine switchover (UI reads `AIAppModel`; the approval continuation moves off `ClaudeCodeStore`).

**Architecture:** New v8 view layer in `Brow/components/AI/Views/v8/` reading `AIAppModel.shared.state` (the `@Observable` core from the Foundation). A pure `IslandSurface` state machine maps `AgentEvent`/phase → surface. The closed pill uses a single precedence resolver (AI-attention > AI-running > Music > Mascot). The interactive continuation registry moves from `ClaudeCodeStore` to `AIAppModel` so approve/answer round-trip through the new core. Old `AIPanel`/`AIMonitorSection`/`AIApproveSection`/`AIAskSection` are replaced; `AISessionsTabView` + `AIPanelMockup` deleted; `ClaudeCodeStore` reduced to a rules/sound shim.

**Tech Stack:** SwiftUI + AppKit, Swift `@Observable`, `Network.framework` bridge (Foundation), `CAKeyframeAnimation` (UnifiedBars), `swift-markdown-ui` (new dep, completion markdown), XCTest.

## Global Constraints

- Reuse Brow's existing notch window/shape infra (`BrowSkyLightWindow`, `NotchSpaceManager`, per-screen `BrowViewModel`, `NotchShape`) — do NOT rebuild the window layer. (spec §4.7)
- Palette: ink `#0D0D0F`, paper `#F1EAD9`; status running `#6EA7FF`, waitingForApproval `#F4A4A4`, waitingForAnswer `#FFD58A`, completed `#6FB982`, waiting `#E7A762`; brand claude `#d97742`, codex `#4aa3df`. (spec §4.7 — exact hex)
- Springs: open `spring(response:0.42, dampingFraction:0.8)`, close `smooth(duration:0.3)` (Brow's open spring already matches). (spec §4.7)
- Surface model: `closed → sessionList` (hover/click); `permissionRequested→approvalCard`, `questionAsked→questionCard`, `sessionCompleted→completionCard` auto-present, auto-collapse ~10s idle / pointer-leave; suppress-if-terminal-frontmost. (spec §4.3)
- Closed-pill precedence (single resolver): AI-attention > AI-running (`UnifiedBars`) > Music (`MusicLiveActivity`) > Mascot (`MinimalFaceFeatures`/`BrowMascot`) > empty. AI-attention always wins. (spec §4.8)
- Preserve Music (album-art `matchedGeometryEffect` morph, Home-tab player) and Mascot; restyle to ink/paper. Mascot states map to `SessionPhase`. (spec §4.8)
- Reference source to port from: `/private/tmp/claude-501/-Users-tuanle-projects-Brow/07fd36f3-d934-47ec-8629-1a9cc92fe696/scratchpad/open-vibe-island/Sources/OpenIslandApp/` (`IslandPanelView.swift`, `Views/UnifiedBars.swift`, `Views/V6NotchContent.swift`, `IslandDesignPalette.swift`, `OpenedIslandSurfaceShape.swift`, `V6ClosedPillShape.swift`, `IslandChromeMetrics.swift`, `IslandDebugScenario.swift`) and design bundle `design/v8-bundle/`.
- Testable logic (surface mapping, precedence, grouping/sort/staleness, displayPriority) gets XCTest in `BrowTests` (classic PBXGroup — register every new test file via the gem or it silently runs 0). Pure-visual views get `#Preview`s driven by an `IslandDebugScenario` port + a `build` check.
- `@Observable AIAppModel` bridges to Combine views at `BrowViewCoordinator` where needed.

**Decomposition note:** Detailed tasks 2.1–2.6 below; the switchover slices 2.7–2.9 are outlined and expanded when 2.6 lands (they depend on the concrete view APIs built here). Music/Mascot integration (2.7) has genuine visual-design judgment — flag for a human visual check after 2.7 builds.

---

## File Structure

New: `Brow/components/AI/Views/v8/` — `IslandDesignPalette.swift`, `UnifiedBarsGlyph.swift`, `V8ClosedPill.swift`, `IslandSurface.swift` (state enum + mapping), `IslandSurfaceView.swift` (top-level surface renderer), `SessionListView.swift`, `SessionRowView.swift`, `ApprovalCardView.swift`, `QuestionCardView.swift`, `CompletionCardView.swift`, `IslandDebugScenario.swift`.
New tests: `IslandSurfaceMappingTests.swift`, `ClosedPillPrecedenceTests.swift`, `SessionListDerivationTests.swift`.
Modified: `AIAppModel.swift` (add derived presentation state + continuation registry in 2.9), `ContentView.swift` (mount surfaces, closed-pill precedence, notification auto-present), `ClaudeCodeBridge.swift` (continuation → AIAppModel in 2.9), `ClaudeCodeStore.swift` (→ shim in 2.8).
Deleted (2.8): `AISessionsTabView.swift`, `Mockups/AIPanelMockup.swift`, old `AIPanel.swift`/`AIMonitorSection.swift`/`AIApproveSection.swift`/`AIAskSection.swift`.

---

## Task 2.1: v8 design palette

**Files:** Create `Brow/components/AI/Views/v8/IslandDesignPalette.swift`; Test `BrowTests/IslandDesignPaletteTests.swift`.

**Interfaces:** Produces `enum V6Palette { static let ink, paper }` and `enum IslandStatus { static func tint(for: SessionPhase) -> Color; static let running/waitingForApproval/waitingForAnswer/completed/waiting }` + `AgentTool.brandColor: Color` (from `brandColorHex`).

- [ ] Port `IslandDesignPalette.swift` + `V6Palette` from the reference, as a Brow file, using the exact hex in Global Constraints. Add `Color(hex:)` if Brow lacks one (check `Color+AccentColor.swift` first).
- [ ] Test: `V6Palette.ink` / `.paper` resolve to the exact RGB; `IslandStatus.tint(for: .running)` == the running blue. Register in BrowTests. Fail-first real, then pass.
- [ ] `xcodebuild test -only-testing:BrowTests` + build. Commit `feat(ai-v8): design palette`.

## Task 2.2: UnifiedBars glyph

**Files:** Create `Brow/components/AI/Views/v8/UnifiedBarsGlyph.swift`; Test `BrowTests/UnifiedBarsModeTests.swift`.

**Interfaces:** Produces `UnifiedBarsGlyph: NSViewRepresentable` with `enum Mode { running, waiting, idle }`; `AIAppModel.islandClosedMode: UnifiedBarsGlyph.Mode` (aggregate: waiting > running > idle across surfaced sessions).

- [ ] Port the `CAKeyframeAnimation`-on-`CAShapeLayer` glyph from reference `Views/UnifiedBars.swift` (running = staggered vertical scale wave, `duration 0.9`, per-bar `beginTime` stagger; waiting = opacity pulse split left/right, `duration 1.8`; idle = static, no layer animation). Keep it an `NSViewRepresentable` to avoid SwiftUI re-render cost.
- [ ] Add `AIAppModel.islandClosedMode` computed from `state` (pure) + a unit test on the aggregation (waiting beats running beats idle). Register test.
- [ ] Build + a `#Preview` showing all 3 modes. Commit `feat(ai-v8): UnifiedBars glyph + closed-mode aggregation`.

## Task 2.3: IslandSurface state machine (pure, testable)

**Files:** Create `Brow/components/AI/Views/v8/IslandSurface.swift`; Test `BrowTests/IslandSurfaceMappingTests.swift`.

**Interfaces:** Produces `enum IslandSurface: Equatable { case closed; case sessionList; case approvalCard(sessionID); case questionCard(sessionID); case completionCard(sessionID) }` and `static func notificationSurface(for event: AgentEvent) -> IslandSurface?` (permissionRequested→approvalCard, questionAsked→questionCard, sessionCompleted(non-interrupt)→completionCard, else nil), plus `var autoDismissesWhenPresentedAsNotification: Bool` and `var isNotificationCard: Bool`.

- [ ] Port the mapping + routing rules from reference (`docs/notch-surface-model.md` + `AppModel.notificationSurface(for:)`). Pure enum + functions.
- [ ] Tests (the higher-value part): each event maps to the right surface; interrupt completion → nil; non-events → nil. Register. Fail-first real, then pass.
- [ ] Build + commit `feat(ai-v8): IslandSurface state machine + event mapping`.

## Task 2.4: Closed-pill precedence resolver + V8ClosedPill view

**Files:** Create `Brow/components/AI/Views/v8/V8ClosedPill.swift`; Test `BrowTests/ClosedPillPrecedenceTests.swift`.

**Interfaces:** Produces `enum ClosedPillContent { case aiAttention(AgentSession), aiRunning, music, mascot, empty }` + `AIAppModel.closedPillContent(musicPlaying: Bool, mascotEnabled: Bool) -> ClosedPillContent` (pure, precedence: aiAttention > aiRunning > music > mascot > empty), and `V8ClosedPill` view rendering each in the ink/paper pill (reusing `NotchShape`/closed geometry).

- [ ] Implement the pure precedence resolver on `AIAppModel` + a unit test covering every precedence tie (attention beats music even while playing; running beats music; music beats mascot; empty when nothing). Register test.
- [ ] Build `V8ClosedPill` rendering: AI-attention (status-tinted glyph + count), aiRunning (`UnifiedBarsGlyph`), music (existing `MusicLiveActivity`, restyled to palette), mascot (`BrowMascot`/`MinimalFaceFeatures`). Reuse Brow's closed geometry.
- [ ] Build + `#Preview` per content case. Commit `feat(ai-v8): closed-pill precedence resolver + V8ClosedPill`.

## Task 2.5: Session list + row (grouping/sort/staleness)

**Files:** Create `SessionListView.swift`, `SessionRowView.swift`; Test `BrowTests/SessionListDerivationTests.swift`.

**Interfaces:** Produces `AIAppModel.surfacedSessions`/`islandSessionSections` (ported `displayPriority` scoring + grouping none/state/agent/project + sort attention/lastUpdate + stale-completed dimming), and the views rendering them. Row body tap → jump (stub to existing `TerminalJumpService` for now); chevron → toggle detail.

- [ ] Port `displayPriority`/section/sort/staleness logic onto `AIAppModel` as pure computed state (from reference `AppModel`), with unit tests on ranking + grouping + stale threshold. Register.
- [ ] Build `SessionListView` (header + scroll + rows) and `SessionRowView` (state indicator + headline + agent chip + age + detail chevron), ink/paper styled. "jump-first, spatial-split" tap semantics.
- [ ] Build + `#Preview` via debug scenarios. Commit `feat(ai-v8): session list + row with ranking/grouping/staleness`.

## Task 2.6: Approval / Question / Completion cards (interactive)

**Files:** Create `ApprovalCardView.swift`, `QuestionCardView.swift`, `CompletionCardView.swift`, `IslandSurfaceView.swift` (top-level renderer switching on `IslandSurface`). Completion markdown renders via native `AttributedString(markdown:)`, no SPM dep. Test `BrowTests/CardActionTests.swift`.

**Interfaces:** `ApprovalCardView` (Deny / Allow-once / Always-allow buttons → `AIAppModel.approve`), `QuestionCardView` (option list + freeform → `AIAppModel.answer`), `CompletionCardView` (markdown summary + optional reply). `IslandSurfaceView` renders the current `IslandSurface` from `AIAppModel`.

- [ ] Build the three cards reading the actionable `AgentSession` from `AIAppModel`; wire buttons to `approve`/`answer` (these still only mutate the reducer until 2.9 moves the continuation). Interactive question answering.
- [ ] `IslandSurfaceView` switches surface with the open/close springs + shape morph (reuse Brow's `NotchShape.animatableData`).
- [ ] Test the button→reducer wiring (approve clears request; answer clears question) at the `AIAppModel` level. Register.
- [ ] Render completion markdown via native `AttributedString(markdown:)` (no SPM dep needed). Build + `#Preview` each card. Commit `feat(ai-v8): approval/question/completion cards + surface renderer`.

---

## Later slices (outline — expanded when 2.6 lands)

**2.7 — Mount v8 + Music/Mascot integration.** Replace `AIPanel` in `ContentView.NotchLayout` with `IslandSurfaceView`; wire the closed-pill precedence into the closed-notch strip (replacing the ad-hoc `if/else` chain); auto-present notification cards over any tab and auto-collapse to the prior tab (reuse Brow's auto-expand machinery); map `BrowMascot` states ← `SessionPhase`; restyle Music player/live-activity to ink/paper. **Deliverable:** the v8 experience live for Claude, Music/Mascot first-class. **⚠️ human visual check here.**

**2.8 — Cleanup.** Delete `AISessionsTabView.swift`, `Mockups/AIPanelMockup.swift`, old `AIPanel`/`AIMonitorSection`/`AIApproveSection`/`AIAskSection`; reduce `ClaudeCodeStore` to a rules/sound shim; port `IslandDebugScenario` for `#Preview`s + a DEV harness; remove unused `Pow` dep if still unused; fix the deferred minors (Cocoa SDK-pin on BrowAgentHook, `activityDescription` default, codex message text).

**2.9 — Continuation move (the real switchover).** Move the `withCheckedContinuation` approval registry from `ClaudeCodeStore` to `AIAppModel`; `approve`/`answer` complete the blocked hook connection with the agent-native directive; bridge's permission case awaits `AIAppModel` instead of the store. Remove the additive double-path from Phase 1 (bridge now feeds only `AIAppModel`). **Deliverable:** approvals round-trip through the new core end-to-end; `ClaudeCodeStore` no longer owns live state. Regression: real `claude` session approve/deny/answer/jump via the v8 UI.

---

## Self-Review

**Spec coverage:** v8 palette/shapes/glyph (spec §4.7) → 2.1/2.2/2.4. Surface state machine (§4.3) → 2.3/2.6. Session list (§4.6) → 2.5. Cards + interactive questions (§4.5) → 2.6. Music/Mascot integration (§4.8) → 2.4/2.7. Cleanup (§7) → 2.8. Switchover → 2.9. **Placeholders:** 2.7–2.9 are outline-level by design (depend on 2.1–2.6 APIs), expanded at their start. **Type consistency:** `IslandSurface` cases, `AIAppModel.approve/answer` (from Foundation `resolvePermission(...,at:)`/`answerQuestion(...,at:)`), `ClosedPillContent`, `UnifiedBarsGlyph.Mode` used consistently.

## Execution Handoff
Committed for the record; executed via subagent-driven-development starting at 2.1.
