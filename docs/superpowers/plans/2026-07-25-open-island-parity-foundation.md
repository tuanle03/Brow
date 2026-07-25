# Open Island Parity — Foundation (Phase 0 + Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop Brow's App Sandbox, stand up an installed hook binary, and replace `ClaudeCodeStore` with a clean ported agent-core (`SessionState` reducer + `AIAppModel`) that Claude Code ingestion runs on — all behind the *existing* UI, so nothing looks different yet but the foundation for v8 + Codex + process-monitoring is in place.

**Architecture:** Port Open Island's data model (`AgentSession`/`AgentEvent`/`SessionState` pure reducer) into a new `Brow/components/AI/Core/` group using Swift `@Observable`. Keep Brow's working loopback-HTTP bridge; replace the inline-curl hook with a new `BrowAgentHook` command-line-tool target that enriches payloads and blocks on the HTTP response. The existing `AITaskRegistry`/`AIPanel` UI is repointed at a thin adapter over the new core so behavior is preserved during the swap.

**Tech Stack:** Swift 6.2, SwiftUI + AppKit, Xcode project (not SwiftPM), `Network.framework` (existing bridge), XCTest (new test target), `Defaults`/`KeyboardShortcuts`/`Sparkle` (existing).

## Global Constraints

- macOS 14+ deployment target; Swift 6.2. (Verbatim from spec §3.1 / reference `Package.swift`.)
- New AI-core types are `Sendable` + `Codable` where they cross the bridge or persist. (spec §3.2)
- `SessionState.apply(_:)` is a **pure** reducer — no I/O, no singletons, no `Date()` inside; timestamps arrive on the event. (spec §3.2, §10)
- Hook binary is **fail-open**: every error path logs to stderr and the process exits `0`. (spec §4.1)
- Bridge stays bound to `127.0.0.1` only; no new external network exposure. (spec §5)
- Installers are additive/idempotent: back up before mutating, preserve other tools' hooks, never silently reinstall what the user uninstalled. (spec §4.1)
- Naming: agent-agnostic UI/model types prefixed `AI*` or `Agent*`; vendor plumbing prefixed by vendor (`Claude*`, `Codex*`). (Brow convention, spec §3.3)
- Feature stores are `final class … { static let shared }` singletons observed via `@ObservedObject`/`@Observable`, except the per-screen `BrowViewModel`. (Brow convention)

**Decomposition note:** This plan covers **Phase 0 + Phase 1** only. Phases 2–5 (v8 UI, Codex, process-monitoring/jump-back, polish) are outlined at the end (§"Later Phases") and each gets its own detailed plan authored at phase start, because their steps depend on the concrete APIs produced here.

---

## File Structure (Phase 0 + 1)

New group `Brow/components/AI/Core/`:
- `AgentTool.swift` — agent enum + brand/display metadata.
- `SessionPhase.swift` — phase + attachment enums.
- `JumpTarget.swift` — terminal-jump descriptor.
- `PermissionModels.swift` — `PermissionRequest`, `PermissionResolution`, `ClaudePermissionUpdate`.
- `QuestionModels.swift` — `QuestionPrompt`, `QuestionPromptItem`, `QuestionOption`.
- `AgentSession.swift` — canonical session record + `isVisibleInIsland`.
- `AgentEvent.swift` — Codable event enum (Claude/Codex subset).
- `SessionState.swift` — dictionary store + pure `apply` reducer + reconcilers.
- `AIAppModel.swift` — `@MainActor @Observable` owner of `state` + bridge + resolution.
- `ClaudeEventMapping.swift` — decode Claude hook payload → `[AgentEvent]`.

New targets:
- `BrowAgentHook/` — `main.swift`, `HookRuntimeContext.swift`, `BridgePost.swift`.

New test target `BrowTests/`:
- `SessionStateTests.swift`, `ClaudeEventMappingTests.swift`, `AgentSessionVisibilityTests.swift`.

Modified:
- `Brow/Brow.entitlements` — remove sandbox, add automation.
- `Brow.xcodeproj/project.pbxproj` — new targets, embed hook, test target, remove-sandbox build settings.
- `Brow/components/AI/ClaudeCodeBridge.swift` → generalized `AgentBridge` (or kept name, extended).
- `Brow/components/AI/ClaudeCodeHookInstaller.swift` — install `BrowAgentHook` command instead of inline curl.
- `Brow/components/AI/AITaskRegistry.swift` — read from `AIAppModel` via adapter.
- `Brow/components/AI/ClaudeCodeStore.swift` — reduced to a thin compatibility shim, then deleted in Phase 2.

---

## Phase 0 — Sandbox + Hook Binary Groundwork

### Task 0.1: Remove the App Sandbox entitlement

**Files:**
- Modify: `Brow/Brow.entitlements`
- Modify: `Brow.xcodeproj/project.pbxproj` (build settings if sandbox set there)

**Interfaces:**
- Produces: a non-sandboxed `Brow.app` that can `ps`/`lsof`, run installed binaries, and AppleScript other apps.

- [ ] **Step 1: Read current entitlements**

Run: `cat Brow/Brow.entitlements` and note every key.

- [ ] **Step 2: Remove sandbox, add automation keys**

Set `com.apple.security.app-sandbox` to `false` (or delete the key). Add:
```xml
<key>com.apple.security.automation.apple-events</key>
<true/>
```
Keep hardened-runtime-compatible keys. Add to `Brow/Info.plist`:
```xml
<key>NSAppleEventsUsageDescription</key>
<string>Brow uses Apple Events to jump back to the terminal running your coding agent.</string>
```

- [ ] **Step 3: Build**

Run: `xcodebuild -scheme Brow -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 4: Verify sandbox is off at runtime**

Launch the built app, then Run: `codesign -d --entitlements - "$(ls -dt ~/Library/Developer/Xcode/DerivedData/Brow-*/Build/Products/Debug/Brow.app | head -1)" 2>&1 | grep -i sandbox || echo "no sandbox entitlement"`
Expected: `no sandbox entitlement`.

- [ ] **Step 5: Commit**

```bash
git add Brow/Brow.entitlements Brow/Info.plist Brow.xcodeproj/project.pbxproj
git commit -m "chore(sandbox): drop App Sandbox, add Apple Events automation entitlement"
```

### Task 0.2: Add the `BrowAgentHook` command-line target

**Files:**
- Create: `BrowAgentHook/main.swift`
- Create: `BrowAgentHook/HookRuntimeContext.swift`
- Create: `BrowAgentHook/BridgePost.swift`
- Modify: `Brow.xcodeproj/project.pbxproj` (new `com.apple.product-type.tool` target + "Copy Files" embed into `Brow.app/Contents/Helpers/`)

**Interfaces:**
- Produces: an executable `BrowAgentHook` that reads stdin, POSTs `{"source":..,"payload":..,"context":..}` to `http://127.0.0.1:21064/event`, prints the response body to stdout, exits `0`.
- Consumes (later): `AgentBridge`'s `/event` endpoint (Task 0.3).

- [ ] **Step 1: Create the target in Xcode project**

Add a new "Command Line Tool" target named `BrowAgentHook` (product type `com.apple.product-type.tool`), macOS 14 deployment, no dependencies. Add a "Copy Files" build phase on the `Brow` app target: destination `Executables`/`Contents/Helpers`, add `BrowAgentHook`. Add `BrowAgentHook` as a target dependency of `Brow`.

- [ ] **Step 2: Write `HookRuntimeContext.swift`**

```swift
import Foundation

/// Runtime hints captured at hook-invocation time (impossible from inline curl).
struct HookRuntimeContext: Codable {
    var terminalApp: String?
    var tty: String?
    var terminalSessionID: String?
    var cwd: String?

    static func capture(environment: [String: String] = ProcessInfo.processInfo.environment) -> HookRuntimeContext {
        HookRuntimeContext(
            terminalApp: environment["TERM_PROGRAM"] ?? environment["__CFBundleIdentifier"],
            tty: environment["TTY"] ?? currentTTY(),
            terminalSessionID: environment["TERM_SESSION_ID"] ?? environment["ITERM_SESSION_ID"],
            cwd: FileManager.default.currentDirectoryPath
        )
    }

    private static func currentTTY() -> String? {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard ttyname_r(STDERR_FILENO, &buf, buf.count) == 0 else { return nil }
        return String(cString: buf)
    }
}
```

- [ ] **Step 3: Write `BridgePost.swift`**

```swift
import Foundation

enum BridgePost {
    /// Blocking POST. `timeout` is long for interactive events so the agent waits for the user.
    static func send(source: String, payload: Data, context: HookRuntimeContext, timeout: TimeInterval) -> Data? {
        var envelope: [String: Any] = ["source": source]
        envelope["payload"] = (try? JSONSerialization.jsonObject(with: payload)) ?? String(data: payload, encoding: .utf8) ?? ""
        if let ctx = try? JSONEncoder().encode(context),
           let ctxObj = try? JSONSerialization.jsonObject(with: ctx) {
            envelope["context"] = ctxObj
        }
        guard let body = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }

        var req = URLRequest(url: URL(string: "http://127.0.0.1:21064/event")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, _, _ in result = data; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}
```

- [ ] **Step 4: Write `main.swift`**

```swift
import Foundation

// Fail-open: any failure logs to stderr and exits 0 so the agent is never blocked.
func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("[BrowAgentHook] \(message)\n".utf8))
    exit(0)
}

let args = CommandLine.arguments
func flag(_ name: String) -> String? {
    guard let i = args.firstIndex(of: name), i + 1 < args.count else { return nil }
    return args[i + 1]
}
let source = flag("--source") ?? "claude"

let payload = FileHandle.standardInput.readDataToEndOfFile()
let context = HookRuntimeContext.capture()

// Interactive events wait up to 24h (Claude PermissionRequest), else 45s.
let isInteractive = String(data: payload, encoding: .utf8)?.contains("PermissionRequest") ?? false
    || String(data: payload, encoding: .utf8)?.contains("AskUserQuestion") ?? false
let timeout: TimeInterval = isInteractive ? 24 * 60 * 60 : 45

if let response = BridgePost.send(source: source, payload: payload, context: context, timeout: timeout),
   !response.isEmpty {
    FileHandle.standardOutput.write(response)
}
exit(0)
```

- [ ] **Step 5: Build the tool**

Run: `xcodebuild -scheme BrowAgentHook -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -20`
Expected: BUILD SUCCEEDED.

- [ ] **Step 6: Smoke-test fail-open (no bridge running)**

Run: `BIN=$(ls -dt ~/Library/Developer/Xcode/DerivedData/Brow-*/Build/Products/Debug/BrowAgentHook | head -1); echo '{"hook_event_name":"Stop"}' | "$BIN" --source claude; echo "exit=$?"`
Expected: `exit=0` (no hang beyond the 45s ceiling; with no listener the connection fails fast).

- [ ] **Step 7: Commit**

```bash
git add BrowAgentHook Brow.xcodeproj/project.pbxproj
git commit -m "feat(hook): add BrowAgentHook installed-binary target (fail-open blocking POST)"
```

### Task 0.3: Generalize the bridge to accept the enriched envelope

**Files:**
- Modify: `Brow/components/AI/ClaudeCodeBridge.swift`

**Interfaces:**
- Consumes: the `{"source","payload","context"}` envelope from `BrowAgentHook`.
- Produces: `AgentBridge.shared` still exposing the existing `start()`, but its `/event` handler now reads `source` and routes; for `source == "claude"` it decodes the inner `payload` exactly as today (backward compatible). Context is attached to the resulting events.

- [ ] **Step 1: Add a failing test for envelope parsing**

Create `BrowTests/AgentBridgeEnvelopeTests.swift`:
```swift
import XCTest
@testable import Brow

final class AgentBridgeEnvelopeTests: XCTestCase {
    func testParsesSourceAndPayload() throws {
        let json = #"{"source":"claude","payload":{"hook_event_name":"Stop","session_id":"s1"},"context":{"tty":"/dev/ttys003"}}"#
        let env = try AgentBridgeEnvelope.decode(Data(json.utf8))
        XCTAssertEqual(env.source, "claude")
        XCTAssertEqual(env.context?.tty, "/dev/ttys003")
        XCTAssertEqual(env.payloadJSON["session_id"] as? String, "s1")
    }
}
```

- [ ] **Step 2: Run it, verify it fails (type not defined)**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/AgentBridgeEnvelopeTests 2>&1 | tail -20`
Expected: FAIL — `AgentBridgeEnvelope` unresolved. (Test target setup is Task 1.1; if not yet present, do 1.1 first, then return.)

- [ ] **Step 3: Implement `AgentBridgeEnvelope`**

Add to `ClaudeCodeBridge.swift`:
```swift
struct AgentBridgeEnvelope {
    let source: String
    let payloadJSON: [String: Any]
    let context: HookRuntimeContextDTO?

    struct HookRuntimeContextDTO: Decodable { var terminalApp: String?; var tty: String?; var terminalSessionID: String?; var cwd: String? }

    static func decode(_ data: Data) throws -> AgentBridgeEnvelope {
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw NSError(domain: "AgentBridge", code: 1)
        }
        // Back-compat: a raw Claude payload (no "source") is treated as source=claude.
        if let source = obj["source"] as? String, let payload = obj["payload"] as? [String: Any] {
            let ctx = (obj["context"] as? [String: Any]).flatMap {
                try? JSONDecoder().decode(HookRuntimeContextDTO.self, from: JSONSerialization.data(withJSONObject: $0))
            }
            return AgentBridgeEnvelope(source: source, payloadJSON: payload, context: ctx)
        }
        return AgentBridgeEnvelope(source: "claude", payloadJSON: obj, context: nil)
    }
}
```

- [ ] **Step 4: Route `/event` through the envelope**

In the `POST /event` handler, replace direct `ClaudeCodeIncomingEvent.decode` with: decode `AgentBridgeEnvelope`; if `source == "claude"`, re-serialize `payloadJSON` and feed the existing Claude decode path (no behavior change); stash `context` for event enrichment. Leave a `default:` branch logging `unhandled source` for future Codex.

- [ ] **Step 5: Run the test, verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/AgentBridgeEnvelopeTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Brow/components/AI/ClaudeCodeBridge.swift BrowTests/AgentBridgeEnvelopeTests.swift
git commit -m "feat(bridge): accept enriched {source,payload,context} envelope (claude back-compat)"
```

### Task 0.4: Install `BrowAgentHook` instead of inline curl

**Files:**
- Modify: `Brow/components/AI/ClaudeCodeHookInstaller.swift`

**Interfaces:**
- Produces: `ClaudeCodeHookInstaller.install()` copies the bundled `BrowAgentHook` to `~/Library/Application Support/Brow/bin/BrowAgentHook` (chmod 0755, byte-compare `updateIfNeeded`) and writes hook commands of the form `'<managed path>' --source claude` into `~/.claude/settings.json`, preserving the existing back-up/merge/manifest logic.

- [ ] **Step 1: Add `ManagedHookBinary` helper**

```swift
enum ManagedHookBinary {
    static var installedURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brow/bin/BrowAgentHook")
    }
    static var bundledURL: URL? {
        Bundle.main.url(forResource: "BrowAgentHook", withExtension: nil, subdirectory: "Helpers")
            ?? Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("../Helpers/BrowAgentHook").standardizedFileURL
    }
    /// Copies the bundled binary to the managed path if missing or changed. Returns the managed path.
    static func ensureInstalled() throws -> URL { /* mkdir -p, byte-compare, copy, chmod 0o755 */ }
}
```

- [ ] **Step 2: Swap the hook command string**

Replace the inline-`curl` command builder with `"'\(try ManagedHookBinary.ensureInstalled().path)' --source claude"`. Keep the existing `coveredHooks` list, additive merge, stale-key sweep, and uninstall logic **unchanged**.

- [ ] **Step 3: Manual round-trip test (real Claude Code)**

Build+run Brow. In Settings → AI, click Install. Run: `cat ~/.claude/settings.json | grep BrowAgentHook` → expect the managed-path command. Start a `claude` session, trigger a permission prompt; confirm the approval card still appears in Brow and Allow/Deny round-trips to the CLI (same behavior as before the swap).

- [ ] **Step 4: Commit**

```bash
git add Brow/components/AI/ClaudeCodeHookInstaller.swift
git commit -m "feat(hook): install BrowAgentHook binary; retire inline-curl hook command"
```

---

## Phase 1 — Agent Core (ported model + reducer)

### Task 1.1: Add the `BrowTests` unit-test target

**Files:**
- Modify: `Brow.xcodeproj/project.pbxproj`
- Create: `BrowTests/PlaceholderTests.swift`

**Interfaces:**
- Produces: an XCTest target `BrowTests` with `@testable import Brow`, runnable via `xcodebuild test -scheme Brow -only-testing:BrowTests`.

- [ ] **Step 1: Create the test target**

Add a "Unit Testing Bundle" target `BrowTests`, host application `Brow`, macOS 14. Ensure the `Brow` scheme's Test action includes it.

- [ ] **Step 2: Add a trivial passing test**

```swift
import XCTest
@testable import Brow
final class PlaceholderTests: XCTestCase { func testTrue() { XCTAssertTrue(true) } }
```

- [ ] **Step 3: Run the test suite**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests 2>&1 | tail -20`
Expected: PASS. (Establishes the test harness for all later tasks.)

- [ ] **Step 4: Commit**

```bash
git add Brow.xcodeproj/project.pbxproj BrowTests
git commit -m "test: add BrowTests unit-test target"
```

### Task 1.2: Port the value types (`AgentTool`, phases, `JumpTarget`, permission/question models)

**Files:**
- Create: `Brow/components/AI/Core/AgentTool.swift`
- Create: `Brow/components/AI/Core/SessionPhase.swift`
- Create: `Brow/components/AI/Core/JumpTarget.swift`
- Create: `Brow/components/AI/Core/PermissionModels.swift`
- Create: `Brow/components/AI/Core/QuestionModels.swift`

**Interfaces:**
- Produces: `AgentTool` (`.claudeCode`, `.codex`), `SessionPhase` (`.running/.waitingForApproval/.waitingForAnswer/.completed`) with `requiresAttention`, `SessionAttachmentState` (`.attached/.stale/.detached`) with `isLive`, `JumpTarget`, `PermissionRequest`, `PermissionResolution`, `ClaudePermissionUpdate`, `QuestionPrompt`, `QuestionPromptItem`, `QuestionOption`.

- [ ] **Step 1: Write `AgentTool.swift`**

```swift
import SwiftUI

enum AgentTool: String, Codable, Sendable, CaseIterable {
    case claudeCode, codex
    var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    var shortName: String { self == .claudeCode ? "Claude" : "Codex" }
    var brandColorHex: String { self == .claudeCode ? "d97742" : "4aa3df" }
    var isClaudeCodeFork: Bool { self == .claudeCode }
}
```

- [ ] **Step 2: Write `SessionPhase.swift`**

```swift
enum SessionPhase: String, Codable, Sendable { case running, waitingForApproval, waitingForAnswer, completed
    var requiresAttention: Bool { self == .waitingForApproval || self == .waitingForAnswer } }
enum SessionAttachmentState: String, Codable, Sendable { case attached, stale, detached
    var isLive: Bool { self == .attached } }
```

- [ ] **Step 3: Write `JumpTarget.swift`, `PermissionModels.swift`, `QuestionModels.swift`**

Port the field lists from spec §3.2 as `Codable, Sendable, Equatable` structs/enums. `PermissionResolution` is:
```swift
enum PermissionResolution: Sendable {
    case allowOnce(updatedInput: AnyCodable? = nil, updatedPermissions: [ClaudePermissionUpdate] = [])
    case deny(message: String? = nil, interrupt: Bool = false)
}
```
(Reuse Brow's existing `AnyJSON`/`AnyCodable` from `ClaudeCodeEvent.swift` for `updatedInput`.)

- [ ] **Step 4: Add a compile-check test**

```swift
import XCTest
@testable import Brow
final class ValueTypeTests: XCTestCase {
    func testAttention() { XCTAssertTrue(SessionPhase.waitingForApproval.requiresAttention)
        XCTAssertFalse(SessionPhase.running.requiresAttention) }
    func testBrand() { XCTAssertEqual(AgentTool.claudeCode.brandColorHex, "d97742") }
}
```

- [ ] **Step 5: Run tests, verify pass**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/ValueTypeTests 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Brow/components/AI/Core BrowTests/ValueTypeTests.swift
git commit -m "feat(ai-core): port AgentTool/SessionPhase/JumpTarget/permission+question value types"
```

### Task 1.3: Port `AgentSession` + `isVisibleInIsland`

**Files:**
- Create: `Brow/components/AI/Core/AgentSession.swift`
- Test: `BrowTests/AgentSessionVisibilityTests.swift`

**Interfaces:**
- Consumes: all Task 1.2 types.
- Produces: `AgentSession` (`Identifiable, Codable, Equatable, Sendable`) with fields from spec §3.2 and `var isVisibleInIsland: Bool`.

- [ ] **Step 1: Write the failing visibility test**

```swift
import XCTest
@testable import Brow
final class AgentSessionVisibilityTests: XCTestCase {
    func testAttentionAlwaysVisible() {
        var s = AgentSession(id: "1", tool: .claudeCode); s.phase = .waitingForApproval; s.isProcessAlive = false
        XCTAssertTrue(s.isVisibleInIsland)
    }
    func testDeadRunningHidden() {
        var s = AgentSession(id: "2", tool: .claudeCode); s.phase = .running
        s.isProcessAlive = false; s.isHookManaged = true; s.isSessionEnded = true
        XCTAssertFalse(s.isVisibleInIsland)
    }
}
```

- [ ] **Step 2: Run, verify fail** (`AgentSession` undefined).

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/AgentSessionVisibilityTests 2>&1 | tail -20`

- [ ] **Step 3: Implement `AgentSession`** with the ported `isVisibleInIsland` rule (spec §3.2): attention always visible; hook-managed visible until `isSessionEnded`; else visible only while `isProcessAlive`. Provide a memberwise init with sensible defaults so tests can build minimal sessions.

- [ ] **Step 4: Run, verify pass.** Same command as Step 2 → PASS.

- [ ] **Step 5: Commit**

```bash
git add Brow/components/AI/Core/AgentSession.swift BrowTests/AgentSessionVisibilityTests.swift
git commit -m "feat(ai-core): port AgentSession + isVisibleInIsland"
```

### Task 1.4: Port `AgentEvent` (Claude/Codex subset)

**Files:**
- Create: `Brow/components/AI/Core/AgentEvent.swift`
- Test: `BrowTests/AgentEventCodableTests.swift`

**Interfaces:**
- Produces: `AgentEvent` Codable enum with cases `sessionStarted`, `activityUpdated`, `permissionRequested`, `questionAsked`, `sessionCompleted`, `jumpTargetUpdated`, `sessionMetadataUpdated`, `actionableStateResolved`; each payload carries `sessionID` + `timestamp`.

- [ ] **Step 1: Failing round-trip test**

```swift
func testPermissionRequestedRoundTrips() throws {
    let req = PermissionRequest(id: "p1", title: "Run tool", summary: "$ ls", toolName: "Bash")
    let ev = AgentEvent.permissionRequested(.init(sessionID: "s1", timestamp: 1000, request: req))
    let data = try JSONEncoder().encode(ev)
    let back = try JSONDecoder().decode(AgentEvent.self, from: data)
    XCTAssertEqual(ev, back)
}
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** the `type`-discriminated Codable enum with per-case payload structs (`Equatable`).
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(ai-core): port AgentEvent Codable enum (claude/codex subset)`.

### Task 1.5: Port `SessionState` + the pure `apply` reducer (the keystone)

**Files:**
- Create: `Brow/components/AI/Core/SessionState.swift`
- Test: `BrowTests/SessionStateTests.swift`

**Interfaces:**
- Consumes: `AgentSession`, `AgentEvent`, all value types.
- Produces: `struct SessionState { var sessionsByID: [String: AgentSession] }` with `mutating func apply(_ event: AgentEvent)`, `resolvePermission(sessionID:, PermissionResolution)`, `answerQuestion(sessionID:, answers)`, `reconcileAttachmentStates(...)`, `markProcessLiveness(aliveIDs:)` (2-miss eviction), `removeInvisibleSessions()`.

- [ ] **Step 1: Failing test — sessionStarted creates a running session**

```swift
func testSessionStartedCreatesRunning() {
    var st = SessionState()
    st.apply(.sessionStarted(.init(sessionID: "s1", timestamp: 1, tool: .claudeCode, title: "repo")))
    XCTAssertEqual(st.sessionsByID["s1"]?.phase, .running)
}
```

- [ ] **Step 2: Failing test — permissionRequested sets waitingForApproval + stores request**

```swift
func testPermissionRequestSetsPhase() {
    var st = SessionState(); st.apply(.sessionStarted(.init(sessionID: "s1", timestamp: 1, tool: .claudeCode, title: "r")))
    st.apply(.permissionRequested(.init(sessionID: "s1", timestamp: 2, request: PermissionRequest(id: "p", title: "t", summary: "s", toolName: "Bash"))))
    XCTAssertEqual(st.sessionsByID["s1"]?.phase, .waitingForApproval)
    XCTAssertNotNil(st.sessionsByID["s1"]?.permissionRequest)
}
```

- [ ] **Step 3: Failing test — resolvePermission clears the request and returns to running**

```swift
func testResolveClearsRequest() {
    var st = SessionState(); st.apply(.sessionStarted(.init(sessionID: "s1", timestamp: 1, tool: .claudeCode, title: "r")))
    st.apply(.permissionRequested(.init(sessionID: "s1", timestamp: 2, request: PermissionRequest(id: "p", title: "t", summary: "s", toolName: "Bash"))))
    st.resolvePermission(sessionID: "s1", .allowOnce())
    XCTAssertNil(st.sessionsByID["s1"]?.permissionRequest)
    XCTAssertEqual(st.sessionsByID["s1"]?.phase, .running)
}
```

- [ ] **Step 4: Failing test — sessionCompleted sets completed + summary; out-of-order older events ignored**

```swift
func testCompletionAndMonotonicUpdatedAt() {
    var st = SessionState(); st.apply(.sessionStarted(.init(sessionID: "s1", timestamp: 10, tool: .claudeCode, title: "r")))
    st.apply(.sessionCompleted(.init(sessionID: "s1", timestamp: 20, summary: "done")))
    XCTAssertEqual(st.sessionsByID["s1"]?.phase, .completed)
    st.apply(.activityUpdated(.init(sessionID: "s1", timestamp: 5, activity: "late")))  // older
    XCTAssertEqual(st.sessionsByID["s1"]?.phase, .completed)  // not resurrected
}
```

- [ ] **Step 5: Failing test — markProcessLiveness evicts after 2 misses**

```swift
func testTwoMissEviction() {
    var st = SessionState(); st.apply(.sessionStarted(.init(sessionID: "s1", timestamp: 1, tool: .claudeCode, title: "r")))
    st.sessionsByID["s1"]?.isHookManaged = true
    st.markProcessLiveness(aliveIDs: [])  // miss 1
    XCTAssertNotNil(st.sessionsByID["s1"])
    st.markProcessLiveness(aliveIDs: [])  // miss 2 -> ended
    XCTAssertEqual(st.sessionsByID["s1"]?.isSessionEnded, true)
}
```

- [ ] **Step 6: Run all five, verify they fail.**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/SessionStateTests 2>&1 | tail -30`
Expected: FAIL (SessionState undefined).

- [ ] **Step 7: Implement `SessionState`** as a pure reducer. Guard every mutation with a monotonic `updatedAt` check (ignore events older than the session's `updatedAt`, except liveness). `resolvePermission` clears `permissionRequest` and sets `.running`. `markProcessLiveness` increments `processNotSeenCount` for missing hook-managed sessions and sets `isSessionEnded = true, phase = .completed` at 2. No `Date()`, no I/O.

- [ ] **Step 8: Run all five, verify they pass.** Same command as Step 6 → PASS.

- [ ] **Step 9: Commit**

```bash
git add Brow/components/AI/Core/SessionState.swift BrowTests/SessionStateTests.swift
git commit -m "feat(ai-core): SessionState pure reducer with reducer tests"
```

### Task 1.6: Claude payload → `[AgentEvent]` mapping

**Files:**
- Create: `Brow/components/AI/Core/ClaudeEventMapping.swift`
- Test: `BrowTests/ClaudeEventMappingTests.swift`

**Interfaces:**
- Consumes: Brow's existing `ClaudeCodeIncomingEvent`/hook payload types (`ClaudeCodeEvent.swift`) + `HookRuntimeContext`.
- Produces: `func mapClaudeEvent(_ payload: ClaudeCodeIncomingEvent, context: AgentBridgeEnvelope.HookRuntimeContextDTO?) -> [AgentEvent]`.

- [ ] **Step 1: Failing test using a real captured Claude payload fixture**

Add `BrowTests/Fixtures/claude_permission_request.json` (a real `PreToolUse`/`PermissionRequest` body). Test that `mapClaudeEvent` produces one `.permissionRequested` with the right `sessionID` and `toolName`.

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement the mapping** by reusing Brow's existing decode logic in `ClaudeCodeStore.handle*` (extract the pure "payload → domain" bits; leave side effects behind). Map `SessionStart→sessionStarted`, `UserPromptSubmit/PreToolUse/PostToolUse→activityUpdated`, `PermissionRequest→permissionRequested`, `AskUserQuestion→questionAsked`, `Stop/SessionEnd→sessionCompleted`.
- [ ] **Step 4: Run, verify pass.**
- [ ] **Step 5: Commit** `feat(ai-core): map Claude hook payloads to AgentEvent`.

### Task 1.7: `AIAppModel` — own state, wire bridge → reducer, resolve approvals

**Files:**
- Create: `Brow/components/AI/Core/AIAppModel.swift`
- Modify: `Brow/components/AI/ClaudeCodeBridge.swift` (dispatch mapped events into `AIAppModel`)

**Interfaces:**
- Consumes: `SessionState`, `AgentEvent`, `mapClaudeEvent`, the bridge's interactive-continuation mechanism.
- Produces: `@MainActor @Observable final class AIAppModel { static let shared; var state: SessionState; func ingest(_ events: [AgentEvent]); func approve(sessionID:, PermissionResolution); func answer(sessionID:, answers) }`. `approve`/`answer` call the reducer, then complete the bridge's blocked hook continuation with the agent-native directive.

- [ ] **Step 1: Failing test — ingest applies events to state**

```swift
@MainActor func testIngestUpdatesState() {
    let m = AIAppModel()
    m.ingest([.sessionStarted(.init(sessionID: "s1", timestamp: 1, tool: .claudeCode, title: "r"))])
    XCTAssertEqual(m.state.sessionsByID["s1"]?.phase, .running)
}
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement `AIAppModel`.** `ingest` folds events via `state.apply`. `approve`/`answer` update the reducer and resolve the pending bridge continuation (move Brow's existing `withCheckedContinuation` registry from `ClaudeCodeStore` onto `AIAppModel`, keyed by request id). Keep an `init()` for tests + a `shared` singleton for the app.
- [ ] **Step 4: Repoint the bridge** `/event` claude branch to `AIAppModel.shared.ingest(mapClaudeEvent(...))`, and register the interactive continuation on `AIAppModel`.
- [ ] **Step 5: Run test, verify pass.**
- [ ] **Step 6: Commit** `feat(ai-core): AIAppModel owns SessionState and resolves approvals via the bridge`.

### Task 1.8: Adapter — existing UI reads from `AIAppModel` (no visual change)

**Files:**
- Modify: `Brow/components/AI/AITaskRegistry.swift`
- Modify: `Brow/components/AI/ClaudeCodeStore.swift` (reduce to shim)

**Interfaces:**
- Produces: `AITaskRegistry` builds its `[AITask]` from `AIAppModel.shared.state.sessionsByID` (via a small `AgentSession → AITask` projection) instead of from `ClaudeCodeStore`'s queues. `ClaudeCodeStore` becomes a thin shim retaining only anything still referenced (rules, sounds) until Phase 2 deletes it. **The `AIPanel`/`AIMonitorSection`/`AIApproveSection` views are untouched** — they still render `AITask`, so the app looks identical.

- [ ] **Step 1: Write `AgentSession → AITask` projection** (`AITask.from(_ session:)`), mapping phase→`AITaskStatus`, `permissionRequest`→`PendingApproval`, `questionPrompt`→`AIQuestion`.

- [ ] **Step 2: Repoint `AITaskRegistry`** to observe `AIAppModel.shared` (it's `@Observable`; wrap the read in the registry's existing publish cycle, or expose an `@Published mirror` updated from an observation closure so the Combine-based views keep working).

- [ ] **Step 3: Manual regression test** — build+run, real Claude session: Monitor list, Approve card (Allow/Deny/Always), auto-expand, and the rainbow halo all behave exactly as before. This is the "swap the engine, keep the dashboard" checkpoint.

- [ ] **Step 4: Run the full unit suite**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests 2>&1 | tail -20`
Expected: all PASS.

- [ ] **Step 5: Commit** `refactor(ai): drive existing UI from AIAppModel/SessionState; ClaudeCodeStore → shim`.

---

## Later Phases (outline — each expanded into its own plan at phase start)

**Phase 2 — v8 visual + surface state machine.** Files: `Core/IslandSurface.swift` (state enum + `notificationSurface(for:)`), `Views/v8/*` (closed pill, `UnifiedBars` `CAKeyframeAnimation` glyph, session list with grouping/sort/staleness, approval/question/completion cards), `IslandDesignPalette.swift` (ink/paper + status/brand colors). Integrate closed-pill precedence (AI-attention > AI-running > Music > Mascot) and route notification cards over any tab. Interactive question answering. Delete `AISessionsTabView.swift`, `AIPanelMockup.swift`, retire `ClaudeCodeStore`. Add `swift-markdown-ui` for completion markdown. Port `IslandDebugScenario` for `#Preview`s. **Deliverable:** the v8 experience for Claude, Music/Mascot integrated.

**Phase 3 — Codex CLI.** Files: `Core/CodexEventMapping.swift`, `CodexHookInstaller.swift` (`~/.codex/config.toml` + `hooks.json`), `CodexRolloutDiscovery.swift`. Extend the bridge `source == "codex"` branch. **Deliverable:** Codex sessions appear and approve/deny alongside Claude on the same UI.

**Phase 4 — Process monitoring + terminal jump-back.** Files: `Core/ActiveAgentProcessDiscovery.swift` (`ps`/`lsof`), `ProcessMonitoringCoordinator.swift` (adaptive poll, 2-miss eviction, terminal parent-PID walk), `ClaudeTranscriptDiscovery.swift`, `TerminalJumpService.swift` + `TerminalJumpTargetResolver.swift` (Terminal.app/iTerm2/Ghostty/tmux/VS Code/Cursor), session-registry persistence. **Deliverable:** accurate live sessions across restarts + row-tap jump-back.

**Phase 5 — Polish + cleanup.** Notification sounds alignment, staleness/grouping/sort settings surface, onboarding for Automation/Accessibility prompts, remove unused `Pow`, notarized-DMG release path, full `/verify` pass. **Deliverable:** production-ready release.

---

## Self-Review

**Spec coverage (spec §):** §3.1 targets → Tasks 0.2, 1.1. §3.2 model → Tasks 1.2–1.5. §4.1 transport/hooks → Tasks 0.2–0.4. §4.5 approval/question → 1.5/1.7 (backend) + Phase 2 (UI). §4.2 discovery, §4.4 jump-back → Phase 4. §4.3/§4.7/§4.8 v8+Music/Mascot → Phase 2. §5 sandbox → Task 0.1. §7 cleanup → Phase 2. §10 verification → reducer tests in 1.5, fixtures in 1.6, manual E2E in 0.4/1.8. **Gap check:** usage dashboards, Watch/iOS, extra agents, Warp/JetBrains = explicit Non-Goals (spec §2), correctly absent.

**Placeholder scan:** `ManagedHookBinary.ensureInstalled` (Task 0.4 Step 1) and a few Phase-2..5 items are intentionally outline-level and flagged as such (own plan at phase start) — Phase 0/1 tasks contain runnable code + commands. No "TBD/handle edge cases/write tests for the above" in the Phase 0/1 tasks.

**Type consistency:** `AIAppModel.state.sessionsByID` used consistently (Tasks 1.5, 1.7, 1.8). `PermissionResolution.allowOnce/deny` consistent (1.2, 1.5, 1.7). `mapClaudeEvent` signature stable (1.6 → 1.7). `AgentEvent` case names identical across 1.4/1.5/1.7. `BrowAgentHook` binary name + `--source` + port `21064` consistent across 0.2/0.3/0.4.

---

## Execution Handoff

This plan is committed for your review (delivery choice: "review the written plan first"). No implementation runs until you approve.
