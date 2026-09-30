# External Display Brightness & Volume Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** F1/F2 change the brightness and F10/F11/F12 the speaker volume of external monitors over DDC/CI, from any keyboard, with Brow's notch HUD as feedback.

**Architecture:** A new `Brow/Managers/DisplayControl/` module: pure DDC packet/retry/coalescing logic behind a `DDCTransport` protocol, a real Apple-Silicon `IOAVService` transport + IORegistry matcher ported from MonitorControl, a gamma-table dimmer fallback, and a `@MainActor` `DisplayControlRouter` that decides built-in vs DDC vs gamma vs CoreAudio. The existing `MediaKeyInterceptor` event tap gains `keyDown`/`keyUp` handling that matches rebindable `KeyboardShortcuts.Name` bindings and forwards to the router.

**Tech Stack:** Swift 5 language mode, SwiftUI + AppKit, IOKit (private `IOAVService*` via `dlsym`), CoreGraphics (event tap, gamma), CoreAudio, `Defaults`, `KeyboardShortcuts`, XCTest.

**Spec:** `docs/superpowers/specs/2026-09-30-external-display-keys-design.md`

## Global Constraints

- Deployment target macOS 14.0; app target `SWIFT_VERSION = 5.0`; Xcode 26.
- `Brow/Managers` and `BrowTests` are classic PBXGroups: register new files only with `ruby tools/xcodeproj/add_display_control_files.rb` (created in Task 1). Never hand-edit `project.pbxproj`.
- DDC only on Apple Silicon via `IOAVService` (I2C address `0x37`, data address `0x51`); missing symbols → no DDC → gamma fallback. No Intel `IOI2C` path.
- Default bindings: `displayBrightnessDown` F1, `displayBrightnessUp` F2, `displayVolumeMute` F10, `displayVolumeDown` F11, `displayVolumeUp` F12 — all with no modifiers.
- Step 1/16; fine step 1/64 when the binding's modifiers plus `⌥⇧` are held.
- Gamma floor 0.1. 3 consecutive failed DDC writes → display marked no-DDC.
- Defaults keys: `externalDisplayControl: Bool = true`, `externalDisplayLevels: [String: Double] = [:]` keyed `"<displayUUID>.brightness" | ".volume" | ".software"`.
- Existing `BrightnessManager` / `VolumeManager` public API unchanged.
- Tests: XCTest, `@testable import Brow`, run with `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/<Class> 2>&1 | tail -20`.
- Every commit message ends with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Recording a new binding in Settings while the tap is live** — pressing F1 in the recorder must record F1, not change brightness. Pinned by `testSuspendedMatcherMatchesNothing` (Task 5) + `isRecordingShortcut()` (Task 8).
2. **Holding F2 (autorepeat ~30 Hz)** — the DDC bus must not queue 30 writes/s; the monitor ends at the last HUD value. Pinned by `testRapidSubmitsCollapseToLatestValue` (Task 3).
3. **⌘F1/⌘F2 and other modified F-keys** — existing keyboard-backlight shortcuts and app shortcuts must pass through untouched. Pinned by `testCommandF1DoesNotMatchBareF1Binding`, `testOptionAloneDoesNotMatch` (Task 5).
4. **Monitor stops answering DDC mid-session** (OSD DDC off, KVM switch) — after 3 failures F1/F2 must still visibly dim via gamma; one success resets the counter. Pinned by `testThreeFailuresSwitchToGamma`, `testSuccessResetsFailureCount` (Task 6).
5. **Repeated gamma dimming compounding** — each press must scale the *original* table, never the already-dimmed one, and restore must not clobber other apps' gamma when we never dimmed. Pinned by `testOriginalTableCapturedOnce`, `testRestoreAllWithoutDimmingDoesNothing` (Task 4).

---

## File Structure

```
Brow/Managers/DisplayControl/
  DDC/DDCPacket.swift            DDCVCP codes, DDCReading, packet framing + reply parsing (pure)
  DDC/DDCChannel.swift           DDCTransport / DDCChanneling protocols, retrying DDCChannel
  DDC/DDCWriteCoalescer.swift    LevelWriter protocol, latest-value-wins DDCWriteCoalescer
  DDC/Arm64DDCTransport.swift    IOAVService transport (dlsym)
  GammaDimmer.swift              GammaTable, GammaApplying, GammaDimmer, CoreGraphicsGammaApplier
  DisplayKeyBindings.swift       DisplayKeyAction, ShortcutBinding, ShortcutMatcher, SwallowedKeyTracker
  ExternalDisplay.swift          per-monitor state (levels, writers, DDC health)
  DisplayControlRouter.swift     DisplayControlEnvironment protocol + router
  AudioOutput.swift              AudioOutputInfo + CoreAudioOutputs
  DisplayRegistry.swift          CGDisplay ↔ DCPAVServiceProxy matching (MonitorControl port)
  DisplayControlCenter.swift     singleton: lifecycle, rebuild, environment implementation
BrowTests/
  DDCPacketTests.swift  DDCChannelTests.swift  DDCWriteCoalescerTests.swift
  GammaDimmerTests.swift  DisplayKeyBindingsTests.swift  DisplayControlRouterTests.swift
tools/xcodeproj/add_display_control_files.rb
Modified: Brow/Shortcuts/ShortcutConstants.swift, Brow/models/Constants.swift,
          Brow/observers/MediaKeyInterceptor.swift, Brow/BrowViewCoordinator.swift,
          Brow/BrowApp.swift, Brow/components/Settings/SettingsView.swift, THIRD_PARTY_LICENSES
```

---

### Task 1: DDC packet framing + project registration script

**Files:**
- Create: `tools/xcodeproj/add_display_control_files.rb`
- Create: `Brow/Managers/DisplayControl/DDC/DDCPacket.swift`
- Test: `BrowTests/DDCPacketTests.swift`

**Interfaces:**
- Produces: `enum DDCVCP { static let brightness: UInt8 = 0x10; static let volume: UInt8 = 0x62 }`, `struct DDCReading: Equatable { let current: UInt16; let max: UInt16 }`, `enum DDCPacket { static let replyLength = 11; static func setVCP(_ vcp: UInt8, value: UInt16) -> [UInt8]; static func getVCP(_ vcp: UInt8) -> [UInt8]; static func parseReply(_ reply: [UInt8]) -> DDCReading? }`

- [ ] **Step 1: Create the registration script**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# Registers the external-display-control sources (+ tests) in Brow.xcodeproj.
# `Brow/Managers` and `BrowTests` are classic PBXGroups, not file-system-
# synchronized groups, so new .swift files are invisible to the build until
# they are added to a Sources build phase — never hand-edit project.pbxproj.
#
# Idempotent, and only files that already exist on disk are added, so every
# task of the plan re-runs it after creating its files.
#
# Usage: ruby tools/xcodeproj/add_display_control_files.rb

require 'xcodeproj'

ROOT = File.expand_path('../..', __dir__)
PROJECT_PATH = File.join(ROOT, 'Brow.xcodeproj')
SOURCE_DIR = File.join(ROOT, 'Brow', 'Managers', 'DisplayControl')
SOURCES = {
  'DDC' => %w[DDCPacket.swift DDCChannel.swift DDCWriteCoalescer.swift Arm64DDCTransport.swift],
  '' => %w[GammaDimmer.swift DisplayKeyBindings.swift ExternalDisplay.swift DisplayControlRouter.swift
           AudioOutput.swift DisplayRegistry.swift DisplayControlCenter.swift]
}.freeze
TESTS = %w[DDCPacketTests.swift DDCChannelTests.swift DDCWriteCoalescerTests.swift GammaDimmerTests.swift
           DisplayKeyBindingsTests.swift DisplayControlRouterTests.swift].freeze

project = Xcodeproj::Project.open(PROJECT_PATH)
app_target = project.targets.find { |t| t.name == 'Brow' } or raise "Could not find app target 'Brow'"
test_target = project.targets.find { |t| t.name == 'BrowTests' } or raise "Could not find test target 'BrowTests'"

def ensure_in_target(group, filename, target)
  ref = group.files.find { |f| f.path == filename } || group.new_file(filename)
  target.add_file_references([ref]) unless target.source_build_phase.files_references.include?(ref)
end

managers = project.main_group['Brow']['managers'] or raise "Could not find 'Brow > managers' group"
dc_group = managers['DisplayControl'] || managers.new_group('DisplayControl', 'DisplayControl')

SOURCES.each do |subdir, files|
  group = subdir.empty? ? dc_group : (dc_group[subdir] || dc_group.new_group(subdir, subdir))
  files.each do |filename|
    next unless File.exist?(File.join(SOURCE_DIR, subdir, filename))

    ensure_in_target(group, filename, app_target)
    puts "Ensured DisplayControl/#{subdir.empty? ? '' : "#{subdir}/"}#{filename} in Brow"
  end
end

tests_group = project.main_group['BrowTests'] or raise "Could not find 'BrowTests' group"
TESTS.each do |filename|
  next unless File.exist?(File.join(ROOT, 'BrowTests', filename))

  ensure_in_target(tests_group, filename, test_target)
  puts "Ensured BrowTests/#{filename} in BrowTests"
end

project.save
puts "Saved #{PROJECT_PATH}"
```

- [ ] **Step 2: Write the failing test** — `BrowTests/DDCPacketTests.swift`

Fixture bytes were computed from MonitorControl's `performDDCCommunication` framing (`[0x80|(n+1), n] + send + [chk]`, set seed `0x6E^0x51`, get seed `0x6E`, reply seed `0x50`).

```swift
import XCTest
@testable import Brow

final class DDCPacketTests: XCTestCase {
    func testSetBrightnessPacket() {
        XCTAssertEqual(DDCPacket.setVCP(DDCVCP.brightness, value: 50), [0x84, 0x03, 0x10, 0x00, 0x32, 0x9A])
    }

    func testSetPacketSplitsHighByte() {
        XCTAssertEqual(DDCPacket.setVCP(DDCVCP.brightness, value: 300), [0x84, 0x03, 0x10, 0x01, 0x2C, 0x85])
    }

    func testSetVolumePacket() {
        XCTAssertEqual(DDCPacket.setVCP(DDCVCP.volume, value: 30), [0x84, 0x03, 0x62, 0x00, 0x1E, 0xC4])
    }

    func testGetPackets() {
        XCTAssertEqual(DDCPacket.getVCP(DDCVCP.brightness), [0x82, 0x01, 0x10, 0xFD])
        XCTAssertEqual(DDCPacket.getVCP(DDCVCP.volume), [0x82, 0x01, 0x62, 0x8F])
    }

    func testParseValidBrightnessReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]
        XCTAssertEqual(DDCPacket.parseReply(reply), DDCReading(current: 50, max: 100))
    }

    func testParseValidVolumeReply() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x62, 0x00, 0x00, 0x64, 0x00, 0x1E, 0xAC]
        XCTAssertEqual(DDCPacket.parseReply(reply), DDCReading(current: 30, max: 100))
    }

    func testParseRejectsBadChecksum() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF3]
        XCTAssertNil(DDCPacket.parseReply(reply))
    }

    func testParseRejectsShortReply() {
        XCTAssertNil(DDCPacket.parseReply([0x6E, 0x88, 0x02]))
    }

    func testParseRejectsAllZeros() {
        XCTAssertNil(DDCPacket.parseReply([UInt8](repeating: 0, count: DDCPacket.replyLength)))
    }

    func testParseRejectsZeroMax() {
        let reply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x00, 0x00, 0x32, 0x96]
        XCTAssertNil(DDCPacket.parseReply(reply))
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Create an empty `Brow/Managers/DisplayControl/DDC/DDCPacket.swift` (just `import Foundation`) so the script can register it, then:

Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DDCPacketTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'DDCPacket' in scope`.

- [ ] **Step 4: Implement** — `Brow/Managers/DisplayControl/DDC/DDCPacket.swift`

```swift
//
//  DDCPacket.swift
//  Brow
//
//  DDC/CI framing for Apple Silicon IOAVService I2C writes. Framing and
//  checksum seeds are copied from MonitorControl's
//  `Arm64DDC.performDDCCommunication` (MIT) — do not "fix" the get seed.
//

import Foundation

enum DDCVCP {
    static let brightness: UInt8 = 0x10
    static let volume: UInt8 = 0x62
}

struct DDCReading: Equatable {
    let current: UInt16
    let max: UInt16
}

enum DDCPacket {
    static let replyLength = 11

    static func setVCP(_ vcp: UInt8, value: UInt16) -> [UInt8] {
        frame([vcp, UInt8(value >> 8), UInt8(value & 0xFF)])
    }

    static func getVCP(_ vcp: UInt8) -> [UInt8] {
        frame([vcp])
    }

    /// Parses an 11-byte "VCP feature reply": bytes 6-7 max, 8-9 current,
    /// byte 10 checksum seeded with 0x50.
    static func parseReply(_ reply: [UInt8]) -> DDCReading? {
        guard reply.count == replyLength,
              checksum(seed: 0x50, reply.dropLast()) == reply[replyLength - 1] else { return nil }
        let max = UInt16(reply[6]) << 8 | UInt16(reply[7])
        let current = UInt16(reply[8]) << 8 | UInt16(reply[9])
        guard max > 0 else { return nil }
        return DDCReading(current: min(current, max), max: max)
    }

    static func checksum<S: Sequence>(seed: UInt8, _ bytes: S) -> UInt8 where S.Element == UInt8 {
        bytes.reduce(seed, ^)
    }

    private static func frame(_ send: [UInt8]) -> [UInt8] {
        var packet = [UInt8(0x80 | (send.count + 1)), UInt8(send.count)] + send
        let seed: UInt8 = send.count == 1 ? 0x6E : 0x6E ^ 0x51
        packet.append(checksum(seed: seed, packet))
        return packet
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DDCPacketTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 10 tests passed.

- [ ] **Step 6: Commit**

```bash
git add tools/xcodeproj/add_display_control_files.rb Brow/Managers/DisplayControl/DDC/DDCPacket.swift BrowTests/DDCPacketTests.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): DDC/CI packet framing and reply parsing

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Retrying DDC channel

**Files:**
- Create: `Brow/Managers/DisplayControl/DDC/DDCChannel.swift`
- Test: `BrowTests/DDCChannelTests.swift`

**Interfaces:**
- Consumes: `DDCPacket.setVCP/getVCP/parseReply/replyLength`, `DDCReading` (Task 1)
- Produces:
  - `protocol DDCTransport: AnyObject { func write(_ packet: [UInt8]) -> Bool; func read(count: Int) -> [UInt8]? }`
  - `protocol DDCChanneling { func write(vcp: UInt8, value: UInt16) -> Bool; func read(vcp: UInt8) -> DDCReading? }`
  - `struct DDCChannel: DDCChanneling { init(transport: DDCTransport, sleep: @escaping (UInt32) -> Void = { usleep($0) }) }` with `static let attempts = 3, writeCycles = 2`, `static let writeSleep: UInt32 = 10_000, readSleep: UInt32 = 50_000, retrySleep: UInt32 = 20_000`

- [ ] **Step 1: Write the failing test** — `BrowTests/DDCChannelTests.swift`

```swift
import XCTest
@testable import Brow

private final class FakeTransport: DDCTransport {
    var writeResults: [Bool] = []          // consumed in order; empty → true
    var readResult: [UInt8]?
    private(set) var writes: [[UInt8]] = []
    private(set) var readCount = 0

    func write(_ packet: [UInt8]) -> Bool {
        writes.append(packet)
        return writeResults.isEmpty ? true : writeResults.removeFirst()
    }

    func read(count: Int) -> [UInt8]? {
        readCount += 1
        return readResult
    }
}

final class DDCChannelTests: XCTestCase {
    private var sleeps: [UInt32] = []
    private func channel(_ t: FakeTransport) -> DDCChannel {
        DDCChannel(transport: t, sleep: { [unowned self] in self.sleeps.append($0) })
    }

    private let validReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xF2]

    func testWriteSucceedsOnFirstAttemptWithTwoWriteCycles() {
        let t = FakeTransport()
        XCTAssertTrue(channel(t).write(vcp: DDCVCP.brightness, value: 50))
        XCTAssertEqual(t.writes, [DDCPacket.setVCP(0x10, value: 50), DDCPacket.setVCP(0x10, value: 50)])
    }

    func testWriteRetriesAfterFailedAttempt() {
        let t = FakeTransport()
        t.writeResults = [false, false, true, true]
        XCTAssertTrue(channel(t).write(vcp: DDCVCP.brightness, value: 50))
        XCTAssertEqual(t.writes.count, 4)
        XCTAssertTrue(sleeps.contains(DDCChannel.retrySleep))
    }

    func testWriteGivesUpAfterThreeAttempts() {
        let t = FakeTransport()
        t.writeResults = Array(repeating: false, count: 20)
        XCTAssertFalse(channel(t).write(vcp: DDCVCP.brightness, value: 50))
        XCTAssertEqual(t.writes.count, DDCChannel.attempts * DDCChannel.writeCycles)
    }

    func testReadReturnsParsedReply() {
        let t = FakeTransport()
        t.readResult = validReply
        XCTAssertEqual(channel(t).read(vcp: DDCVCP.brightness), DDCReading(current: 50, max: 100))
        XCTAssertEqual(t.writes.first, DDCPacket.getVCP(0x10))
        XCTAssertTrue(sleeps.contains(DDCChannel.readSleep))
    }

    func testReadGivesUpOnGarbageReplies() {
        let t = FakeTransport()
        t.readResult = [UInt8](repeating: 0, count: DDCPacket.replyLength)
        XCTAssertNil(channel(t).read(vcp: DDCVCP.brightness))
        XCTAssertEqual(t.readCount, DDCChannel.attempts)
    }

    func testReadDoesNotReadWhenRequestWriteFails() {
        let t = FakeTransport()
        t.writeResults = Array(repeating: false, count: 20)
        t.readResult = validReply
        XCTAssertNil(channel(t).read(vcp: DDCVCP.brightness))
        XCTAssertEqual(t.readCount, 0)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Create `DDCChannel.swift` containing only `import Foundation`, then:
Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DDCChannelTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find type 'DDCTransport' in scope`.

- [ ] **Step 3: Implement** — `Brow/Managers/DisplayControl/DDC/DDCChannel.swift`

```swift
//
//  DDCChannel.swift
//  Brow
//
//  Retrying VCP read/write over a raw I2C transport. Timings follow
//  MonitorControl's Arm64DDC defaults (2 write cycles 10 ms apart, 50 ms
//  before reading a reply, 20 ms between attempts).
//

import Foundation

protocol DDCTransport: AnyObject {
    func write(_ packet: [UInt8]) -> Bool
    func read(count: Int) -> [UInt8]?
}

protocol DDCChanneling {
    func write(vcp: UInt8, value: UInt16) -> Bool
    func read(vcp: UInt8) -> DDCReading?
}

struct DDCChannel: DDCChanneling {
    static let attempts = 3
    static let writeCycles = 2
    static let writeSleep: UInt32 = 10_000
    static let readSleep: UInt32 = 50_000
    static let retrySleep: UInt32 = 20_000

    let transport: DDCTransport
    let sleep: (UInt32) -> Void

    init(transport: DDCTransport, sleep: @escaping (UInt32) -> Void = { usleep($0) }) {
        self.transport = transport
        self.sleep = sleep
    }

    func write(vcp: UInt8, value: UInt16) -> Bool {
        let packet = DDCPacket.setVCP(vcp, value: value)
        for attempt in 0..<Self.attempts {
            if send(packet) { return true }
            if attempt < Self.attempts - 1 { sleep(Self.retrySleep) }
        }
        return false
    }

    func read(vcp: UInt8) -> DDCReading? {
        let packet = DDCPacket.getVCP(vcp)
        for attempt in 0..<Self.attempts {
            if send(packet) {
                sleep(Self.readSleep)
                if let bytes = transport.read(count: DDCPacket.replyLength),
                   let reading = DDCPacket.parseReply(bytes) {
                    return reading
                }
            }
            if attempt < Self.attempts - 1 { sleep(Self.retrySleep) }
        }
        return nil
    }

    /// One attempt = `writeCycles` writes; the attempt succeeds if the last one did.
    private func send(_ packet: [UInt8]) -> Bool {
        var ok = false
        for _ in 0..<Self.writeCycles {
            sleep(Self.writeSleep)
            ok = transport.write(packet)
        }
        return ok
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DDCChannelTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 6 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Brow/Managers/DisplayControl/DDC/DDCChannel.swift BrowTests/DDCChannelTests.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): retrying DDC channel over I2C transport

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: Latest-value-wins write coalescer

**Files:**
- Create: `Brow/Managers/DisplayControl/DDC/DDCWriteCoalescer.swift`
- Test: `BrowTests/DDCWriteCoalescerTests.swift`

**Interfaces:**
- Consumes: `DDCChanneling`, `DDCReading` (Task 2)
- Produces:
  - `protocol LevelWriter: AnyObject { func submit(_ value: UInt16) }`
  - `final class DDCWriteCoalescer: LevelWriter { typealias Executor = (@escaping () -> Void) -> Void; init(vcp: UInt8, channel: DDCChanneling, executor: @escaping Executor); var onResult: ((Bool) -> Void)? }` — `onResult` is called on the executor's thread after every write.

- [ ] **Step 1: Write the failing test** — `BrowTests/DDCWriteCoalescerTests.swift`

```swift
import XCTest
@testable import Brow

private final class RecordingChannel: DDCChanneling {
    var result = true
    var onWrite: ((UInt16) -> Void)?
    private(set) var written: [UInt16] = []

    func write(vcp: UInt8, value: UInt16) -> Bool {
        written.append(value)
        onWrite?(value)
        return result
    }

    func read(vcp: UInt8) -> DDCReading? { nil }
}

/// Holds scheduled blocks until the test runs them.
private final class ManualExecutor {
    private(set) var blocks: [() -> Void] = []
    func schedule(_ block: @escaping () -> Void) { blocks.append(block) }
    func runAll() {
        let pending = blocks
        blocks.removeAll()
        pending.forEach { $0() }
    }
}

final class DDCWriteCoalescerTests: XCTestCase {
    func testRapidSubmitsCollapseToLatestValue() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: channel, executor: executor.schedule)

        for value in UInt16(1)...10 { writer.submit(value) }
        XCTAssertEqual(executor.blocks.count, 1, "only one drain is scheduled while one is pending")

        executor.runAll()
        XCTAssertEqual(channel.written, [10])
    }

    func testSubmitDuringWriteIsDrainedInSamePass() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: channel, executor: executor.schedule)
        channel.onWrite = { value in if value == 1 { writer.submit(2) } }

        writer.submit(1)
        executor.runAll()

        XCTAssertEqual(channel.written, [1, 2])
        XCTAssertTrue(executor.blocks.isEmpty, "no extra drain scheduled while draining")
    }

    func testNewSubmitAfterDrainSchedulesAgain() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: channel, executor: executor.schedule)

        writer.submit(5)
        executor.runAll()
        writer.submit(6)
        XCTAssertEqual(executor.blocks.count, 1)
        executor.runAll()
        XCTAssertEqual(channel.written, [5, 6])
    }

    func testReportsEachWriteResult() {
        let channel = RecordingChannel()
        let executor = ManualExecutor()
        let writer = DDCWriteCoalescer(vcp: DDCVCP.volume, channel: channel, executor: executor.schedule)
        var results: [Bool] = []
        writer.onResult = { results.append($0) }

        writer.submit(1)
        executor.runAll()
        channel.result = false
        writer.submit(2)
        executor.runAll()

        XCTAssertEqual(results, [true, false])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Create `DDCWriteCoalescer.swift` containing only `import Foundation`, then:
Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DDCWriteCoalescerTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'DDCWriteCoalescer' in scope`.

- [ ] **Step 3: Implement** — `Brow/Managers/DisplayControl/DDC/DDCWriteCoalescer.swift`

```swift
//
//  DDCWriteCoalescer.swift
//  Brow
//
//  A DDC write takes ~50 ms; key autorepeat fires ~30×/s. Only the most
//  recent target value is ever written — intermediate values are dropped.
//

import Foundation

protocol LevelWriter: AnyObject {
    func submit(_ value: UInt16)
}

final class DDCWriteCoalescer: LevelWriter {
    typealias Executor = (@escaping () -> Void) -> Void

    /// Called on the executor's thread after every write.
    var onResult: ((Bool) -> Void)?

    private let vcp: UInt8
    private let channel: DDCChanneling
    private let executor: Executor
    private let lock = NSLock()
    private var pending: UInt16?
    private var draining = false

    init(vcp: UInt8, channel: DDCChanneling, executor: @escaping Executor) {
        self.vcp = vcp
        self.channel = channel
        self.executor = executor
    }

    func submit(_ value: UInt16) {
        lock.lock()
        pending = value
        let shouldSchedule = !draining
        draining = true
        lock.unlock()

        if shouldSchedule {
            executor { [self] in drain() }
        }
    }

    private func drain() {
        while true {
            lock.lock()
            guard let value = pending else {
                draining = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()

            let ok = channel.write(vcp: vcp, value: value)
            onResult?(ok)
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DDCWriteCoalescerTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 4 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Brow/Managers/DisplayControl/DDC/DDCWriteCoalescer.swift BrowTests/DDCWriteCoalescerTests.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): coalesce DDC writes to the latest value

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Gamma dimmer fallback

**Files:**
- Create: `Brow/Managers/DisplayControl/GammaDimmer.swift`
- Test: `BrowTests/GammaDimmerTests.swift`

**Interfaces:**
- Produces:
  - `struct GammaTable: Equatable { var red, green, blue: [CGGammaValue] }`
  - `protocol GammaApplying { func currentTable(for displayID: CGDirectDisplayID) -> GammaTable?; func apply(_ table: GammaTable, to displayID: CGDirectDisplayID); func restoreSystemTables() }`
  - `final class GammaDimmer { static let minimumLevel = 0.1; init(applier: GammaApplying); func setLevel(_ level: Double, for displayID: CGDirectDisplayID); func restoreAll(); static func scaled(_ table: GammaTable, level: Double) -> GammaTable }`
  - `struct CoreGraphicsGammaApplier: GammaApplying`

- [ ] **Step 1: Write the failing test** — `BrowTests/GammaDimmerTests.swift`

```swift
import XCTest
@testable import Brow

private final class FakeGammaApplier: GammaApplying {
    var table: GammaTable? = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
    private(set) var currentTableCalls = 0
    private(set) var applied: [(GammaTable, CGDirectDisplayID)] = []
    private(set) var restoreCalls = 0

    func currentTable(for displayID: CGDirectDisplayID) -> GammaTable? {
        currentTableCalls += 1
        return table
    }
    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) { applied.append((table, displayID)) }
    func restoreSystemTables() { restoreCalls += 1 }
}

final class GammaDimmerTests: XCTestCase {
    private func assertChannel(_ actual: [CGGammaValue], _ expected: [CGGammaValue], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual.count, expected.count, file: file, line: line)
        for (a, e) in zip(actual, expected) { XCTAssertEqual(a, e, accuracy: 0.0001, file: file, line: line) }
    }

    func testScaledHalvesTable() {
        let t = GammaTable(red: [0, 0.5, 1], green: [0, 0.5, 1], blue: [0, 0.5, 1])
        let s = GammaDimmer.scaled(t, level: 0.5)
        assertChannel(s.red, [0, 0.25, 0.5])
        assertChannel(s.blue, [0, 0.25, 0.5])
    }

    func testScaledNeverGoesBelowFloor() {
        let t = GammaTable(red: [1], green: [1], blue: [1])
        assertChannel(GammaDimmer.scaled(t, level: 0).red, [0.1])
    }

    func testFullLevelAppliesOriginal() {
        let applier = FakeGammaApplier()
        let dimmer = GammaDimmer(applier: applier)
        dimmer.setLevel(1, for: 7)
        XCTAssertEqual(applier.applied.last?.0, applier.table)
        XCTAssertEqual(applier.applied.last?.1, 7)
    }

    func testOriginalTableCapturedOnce() {
        let applier = FakeGammaApplier()
        let dimmer = GammaDimmer(applier: applier)
        dimmer.setLevel(0.5, for: 7)
        applier.table = GammaTable(red: [0, 0.25, 0.5], green: [0, 0.25, 0.5], blue: [0, 0.25, 0.5]) // what the screen now reports
        dimmer.setLevel(0.5, for: 7)

        XCTAssertEqual(applier.currentTableCalls, 1)
        assertChannel(applier.applied.last!.0.red, [0, 0.25, 0.5]) // scales the original, not the dimmed table
    }

    func testRestoreAllRestoresAndForgetsOriginals() {
        let applier = FakeGammaApplier()
        let dimmer = GammaDimmer(applier: applier)
        dimmer.setLevel(0.5, for: 7)
        dimmer.restoreAll()
        XCTAssertEqual(applier.restoreCalls, 1)

        dimmer.setLevel(0.5, for: 7)
        XCTAssertEqual(applier.currentTableCalls, 2, "original re-captured after restore")
    }

    func testRestoreAllWithoutDimmingDoesNothing() {
        let applier = FakeGammaApplier()
        GammaDimmer(applier: applier).restoreAll()
        XCTAssertEqual(applier.restoreCalls, 0, "must not reset other apps' gamma (f.lux) when we never dimmed")
    }

    func testMissingTableAppliesNothing() {
        let applier = FakeGammaApplier()
        applier.table = nil
        GammaDimmer(applier: applier).setLevel(0.5, for: 7)
        XCTAssertTrue(applier.applied.isEmpty)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Create `GammaDimmer.swift` containing only `import CoreGraphics`, then:
Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/GammaDimmerTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find type 'GammaApplying' in scope`.

- [ ] **Step 3: Implement** — `Brow/Managers/DisplayControl/GammaDimmer.swift`

```swift
//
//  GammaDimmer.swift
//  Brow
//
//  Software dimming for monitors without DDC/CI: scales the display's
//  original gamma transfer table. Can only dim, never exceed the monitor's
//  hardware brightness.
//

import CoreGraphics

struct GammaTable: Equatable {
    var red: [CGGammaValue]
    var green: [CGGammaValue]
    var blue: [CGGammaValue]
}

protocol GammaApplying {
    func currentTable(for displayID: CGDirectDisplayID) -> GammaTable?
    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID)
    func restoreSystemTables()
}

final class GammaDimmer {
    static let minimumLevel = 0.1

    private let applier: GammaApplying
    private var originals: [CGDirectDisplayID: GammaTable] = [:]

    init(applier: GammaApplying) {
        self.applier = applier
    }

    func setLevel(_ level: Double, for displayID: CGDirectDisplayID) {
        let original: GammaTable
        if let cached = originals[displayID] {
            original = cached
        } else {
            guard let table = applier.currentTable(for: displayID) else { return }
            originals[displayID] = table
            original = table
        }
        applier.apply(level >= 1 ? original : Self.scaled(original, level: level), to: displayID)
    }

    func restoreAll() {
        guard !originals.isEmpty else { return }
        originals.removeAll()
        applier.restoreSystemTables()
    }

    static func scaled(_ table: GammaTable, level: Double) -> GammaTable {
        let factor = CGGammaValue(max(minimumLevel, min(1, level)))
        return GammaTable(
            red: table.red.map { $0 * factor },
            green: table.green.map { $0 * factor },
            blue: table.blue.map { $0 * factor }
        )
    }
}

struct CoreGraphicsGammaApplier: GammaApplying {
    func currentTable(for displayID: CGDirectDisplayID) -> GammaTable? {
        let capacity = CGDisplayGammaTableCapacity(displayID)
        guard capacity > 0 else { return nil }
        var red = [CGGammaValue](repeating: 0, count: Int(capacity))
        var green = red
        var blue = red
        var count: UInt32 = 0
        guard CGGetDisplayTransferByTable(displayID, capacity, &red, &green, &blue, &count) == .success,
              count > 0 else { return nil }
        let n = Int(count)
        return GammaTable(red: Array(red.prefix(n)), green: Array(green.prefix(n)), blue: Array(blue.prefix(n)))
    }

    func apply(_ table: GammaTable, to displayID: CGDirectDisplayID) {
        _ = CGSetDisplayTransferByTable(displayID, UInt32(table.red.count), table.red, table.green, table.blue)
    }

    func restoreSystemTables() {
        CGDisplayRestoreColorSyncSettings()
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/GammaDimmerTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 7 tests passed.

- [ ] **Step 5: Commit**

```bash
git add Brow/Managers/DisplayControl/GammaDimmer.swift BrowTests/GammaDimmerTests.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): gamma-table dimming fallback

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Key bindings + shortcut matching

**Files:**
- Modify: `Brow/Shortcuts/ShortcutConstants.swift` (add 5 names inside the existing `extension KeyboardShortcuts.Name`)
- Create: `Brow/Managers/DisplayControl/DisplayKeyBindings.swift`
- Test: `BrowTests/DisplayKeyBindingsTests.swift`

**Interfaces:**
- Produces:
  - `KeyboardShortcuts.Name.displayBrightnessDown / displayBrightnessUp / displayVolumeMute / displayVolumeDown / displayVolumeUp`
  - `enum DisplayKeyAction: CaseIterable, Equatable { case brightnessDown, brightnessUp, volumeMute, volumeDown, volumeUp; var shortcutName: KeyboardShortcuts.Name }`
  - `struct ShortcutBinding: Equatable { let action: DisplayKeyAction; let keyCode: Int; let modifiers: NSEvent.ModifierFlags; init(action:keyCode:modifiers:); init(action:shortcut:) }`
  - `enum ShortcutMatch: Equatable { case none; case action(DisplayKeyAction, fine: Bool) }`
  - `enum ShortcutMatcher { static func normalize(_:) -> NSEvent.ModifierFlags; static func match(keyCode: Int, flags: NSEvent.ModifierFlags, bindings: [ShortcutBinding], suspended: Bool) -> ShortcutMatch; static func currentBindings() -> [ShortcutBinding] }`
  - `struct SwallowedKeyTracker { mutating func noteSwallowedDown(_ keyCode: Int); mutating func shouldSwallowUp(_ keyCode: Int) -> Bool }`

- [ ] **Step 1: Add the shortcut names** — append inside `extension KeyboardShortcuts.Name { … }` in `Brow/Shortcuts/ShortcutConstants.swift`, after `aiApprovalDeny`:

```swift
    // External displays — matched in MediaKeyInterceptor's event tap, never
    // registered as Carbon hotkeys (so bare F-keys and autorepeat work).
    static let displayBrightnessDown = Self("displayBrightnessDown", default: .init(.f1))
    static let displayBrightnessUp   = Self("displayBrightnessUp",   default: .init(.f2))
    static let displayVolumeMute     = Self("displayVolumeMute",     default: .init(.f10))
    static let displayVolumeDown     = Self("displayVolumeDown",     default: .init(.f11))
    static let displayVolumeUp       = Self("displayVolumeUp",       default: .init(.f12))
```

- [ ] **Step 2: Write the failing test** — `BrowTests/DisplayKeyBindingsTests.swift`

Carbon key codes: F1 = 122, F2 = 120, F10 = 109, F11 = 103, F12 = 111, A = 0.

```swift
import AppKit
import XCTest
@testable import Brow

final class DisplayKeyBindingsTests: XCTestCase {
    private let defaults: [ShortcutBinding] = [
        ShortcutBinding(action: .brightnessDown, keyCode: 122, modifiers: []),
        ShortcutBinding(action: .brightnessUp, keyCode: 120, modifiers: []),
        ShortcutBinding(action: .volumeMute, keyCode: 109, modifiers: []),
        ShortcutBinding(action: .volumeDown, keyCode: 103, modifiers: []),
        ShortcutBinding(action: .volumeUp, keyCode: 111, modifiers: []),
    ]

    private func match(_ keyCode: Int, _ flags: NSEvent.ModifierFlags = [], bindings: [ShortcutBinding]? = nil, suspended: Bool = false) -> ShortcutMatch {
        ShortcutMatcher.match(keyCode: keyCode, flags: flags, bindings: bindings ?? defaults, suspended: suspended)
    }

    func testBareF1MatchesBrightnessDown() {
        XCTAssertEqual(match(122), .action(.brightnessDown, fine: false))
    }

    func testAllDefaultKeysMatch() {
        XCTAssertEqual(match(120), .action(.brightnessUp, fine: false))
        XCTAssertEqual(match(109), .action(.volumeMute, fine: false))
        XCTAssertEqual(match(103), .action(.volumeDown, fine: false))
        XCTAssertEqual(match(111), .action(.volumeUp, fine: false))
    }

    func testFunctionAndCapsLockFlagsAreIgnored() {
        XCTAssertEqual(match(122, [.function]), .action(.brightnessDown, fine: false))
        XCTAssertEqual(match(122, [.capsLock, .numericPad]), .action(.brightnessDown, fine: false))
    }

    func testOptionShiftGivesFineStep() {
        XCTAssertEqual(match(120, [.option, .shift]), .action(.brightnessUp, fine: true))
    }

    func testCommandF1DoesNotMatchBareF1Binding() {
        XCTAssertEqual(match(122, [.command]), .none)
    }

    func testOptionAloneDoesNotMatch() {
        XCTAssertEqual(match(122, [.option]), .none)
    }

    func testUnboundKeyPassesThrough() {
        XCTAssertEqual(match(0), .none)
    }

    func testSuspendedMatcherMatchesNothing() {
        XCTAssertEqual(match(122, suspended: true), .none)
    }

    func testReboundControlF1() {
        let bindings = [ShortcutBinding(action: .brightnessDown, keyCode: 122, modifiers: [.control])]
        XCTAssertEqual(match(122, bindings: bindings), .none)
        XCTAssertEqual(match(122, [.control], bindings: bindings), .action(.brightnessDown, fine: false))
        XCTAssertEqual(match(122, [.control, .option, .shift], bindings: bindings), .action(.brightnessDown, fine: true))
    }

    func testBindingModifiersAreNormalised() {
        let binding = ShortcutBinding(action: .brightnessDown, keyCode: 122, modifiers: [.function])
        XCTAssertEqual(binding.modifiers, [])
    }

    func testSwallowedKeyUpIsSwallowedOnce() {
        var tracker = SwallowedKeyTracker()
        tracker.noteSwallowedDown(122)
        XCTAssertTrue(tracker.shouldSwallowUp(122))
        XCTAssertFalse(tracker.shouldSwallowUp(122))
        XCTAssertFalse(tracker.shouldSwallowUp(120), "keyUp for a key we never swallowed passes through")
    }
}
```

- [ ] **Step 3: Run test to verify it fails**

Create `DisplayKeyBindings.swift` containing only `import AppKit`, then:
Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DisplayKeyBindingsTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find 'ShortcutBinding' in scope`.

- [ ] **Step 4: Implement** — `Brow/Managers/DisplayControl/DisplayKeyBindings.swift`

```swift
//
//  DisplayKeyBindings.swift
//  Brow
//
//  Matches raw keyDown events against the user's external-display bindings.
//  Plain F-keys from non-Apple keyboards arrive as keyDown (not NX media
//  keys), so matching happens here instead of via Carbon hotkeys.
//

import AppKit
import KeyboardShortcuts

enum DisplayKeyAction: CaseIterable, Equatable {
    case brightnessDown, brightnessUp, volumeMute, volumeDown, volumeUp

    var shortcutName: KeyboardShortcuts.Name {
        switch self {
        case .brightnessDown: .displayBrightnessDown
        case .brightnessUp: .displayBrightnessUp
        case .volumeMute: .displayVolumeMute
        case .volumeDown: .displayVolumeDown
        case .volumeUp: .displayVolumeUp
        }
    }
}

struct ShortcutBinding: Equatable {
    let action: DisplayKeyAction
    let keyCode: Int
    let modifiers: NSEvent.ModifierFlags

    init(action: DisplayKeyAction, keyCode: Int, modifiers: NSEvent.ModifierFlags) {
        self.action = action
        self.keyCode = keyCode
        self.modifiers = ShortcutMatcher.normalize(modifiers)
    }

    init(action: DisplayKeyAction, shortcut: KeyboardShortcuts.Shortcut) {
        self.init(action: action, keyCode: shortcut.carbonKeyCode, modifiers: shortcut.modifiers)
    }
}

enum ShortcutMatch: Equatable {
    case none
    case action(DisplayKeyAction, fine: Bool)
}

enum ShortcutMatcher {
    /// F-keys carry `.function` (and sometimes `.numericPad`) on their own;
    /// Caps Lock must not change behaviour. Only these four count.
    static let relevantModifiers: NSEvent.ModifierFlags = [.command, .option, .control, .shift]
    static let fineModifiers: NSEvent.ModifierFlags = [.option, .shift]

    static func normalize(_ flags: NSEvent.ModifierFlags) -> NSEvent.ModifierFlags {
        flags.intersection(relevantModifiers)
    }

    static func match(keyCode: Int, flags: NSEvent.ModifierFlags, bindings: [ShortcutBinding], suspended: Bool) -> ShortcutMatch {
        guard !suspended else { return .none }
        let modifiers = normalize(flags)
        for binding in bindings where binding.keyCode == keyCode && binding.modifiers == modifiers {
            return .action(binding.action, fine: false)
        }
        for binding in bindings where binding.keyCode == keyCode
            && !binding.modifiers.contains(fineModifiers)
            && binding.modifiers.union(fineModifiers) == modifiers {
            return .action(binding.action, fine: true)
        }
        return .none
    }

    static func currentBindings() -> [ShortcutBinding] {
        DisplayKeyAction.allCases.compactMap { action in
            KeyboardShortcuts.getShortcut(for: action.shortcutName).map { ShortcutBinding(action: action, shortcut: $0) }
        }
    }
}

/// Remembers swallowed keyDowns so the matching keyUp is swallowed too —
/// apps must never see a keyUp without its keyDown.
struct SwallowedKeyTracker {
    private var keyCodes = Set<Int>()

    mutating func noteSwallowedDown(_ keyCode: Int) {
        keyCodes.insert(keyCode)
    }

    mutating func shouldSwallowUp(_ keyCode: Int) -> Bool {
        keyCodes.remove(keyCode) != nil
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DisplayKeyBindingsTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 11 tests passed.

- [ ] **Step 6: Commit**

```bash
git add Brow/Shortcuts/ShortcutConstants.swift Brow/Managers/DisplayControl/DisplayKeyBindings.swift BrowTests/DisplayKeyBindingsTests.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): rebindable F-key bindings and matcher

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: ExternalDisplay state + DisplayControlRouter

**Files:**
- Create: `Brow/Managers/DisplayControl/ExternalDisplay.swift`
- Create: `Brow/Managers/DisplayControl/AudioOutput.swift` (value type only in this task; CoreAudio code lands in Task 7)
- Create: `Brow/Managers/DisplayControl/DisplayControlRouter.swift`
- Test: `BrowTests/DisplayControlRouterTests.swift`

**Interfaces:**
- Consumes: `LevelWriter` (Task 3), `DDCReading` (Task 1), `DisplayKeyAction` (Task 5), `SneakContentType` (existing, `Brow/BrowViewCoordinator.swift:13`)
- Produces:
  - `struct AudioOutputInfo: Equatable { let name: String; let isDisplayAudio: Bool }`
  - `@MainActor final class ExternalDisplay: Identifiable` — `let id: CGDirectDisplayID, uuid: String, name: String, brightnessWriter: LevelWriter?, volumeWriter: LevelWriter?`; `var brightness, volume, softwareLevel: Double`; `var volumeBeforeMute: Double?`; `var brightnessMax, volumeMax: UInt16`; `private(set) var ddcAvailable: Bool`; `func recordWriteResult(_ ok: Bool)`; `func applyInitialReadings(brightness: DDCReading?, volume: DDCReading?)`; `func levelKey(_ kind: LevelKind) -> String`; `static func levelKey(uuid: String, kind: LevelKind) -> String`; `static func normalizedName(_ name: String) -> String`; `func statusLabel(hasSpeakers: Bool) -> String`; `enum LevelKind: String { brightness, volume, software }`
  - `@MainActor protocol DisplayControlEnvironment: AnyObject` (methods below)
  - `@MainActor final class DisplayControlRouter { init(environment: DisplayControlEnvironment); func claimsMediaKey(_ action: DisplayKeyAction) -> Bool; func perform(_ action: DisplayKeyAction, fine: Bool) }`

- [ ] **Step 1: Write the failing test** — `BrowTests/DisplayControlRouterTests.swift`

```swift
import XCTest
@testable import Brow

private final class FakeWriter: LevelWriter {
    private(set) var values: [UInt16] = []
    func submit(_ value: UInt16) { values.append(value) }
}

@MainActor
private final class FakeEnvironment: DisplayControlEnvironment {
    var cursorDisplay: CGDirectDisplayID?
    var displays: [ExternalDisplay] = []
    var output: AudioOutputInfo?
    private(set) var gamma: [(level: Double, id: CGDirectDisplayID)] = []
    private(set) var persisted: [String: Double] = [:]
    private(set) var huds: [(type: SneakContentType, value: Double)] = []
    private(set) var builtinDeltas: [Float] = []
    private(set) var systemVolume: [(up: Bool, fine: Bool)] = []
    private(set) var systemMuteToggles = 0

    func displayUnderCursor() -> CGDirectDisplayID? { cursorDisplay }
    func externalDisplays() -> [ExternalDisplay] { displays }
    func defaultAudioOutput() -> AudioOutputInfo? { output }
    func applyGamma(level: Double, to displayID: CGDirectDisplayID) { gamma.append((level, displayID)) }
    func persistLevel(_ value: Double, key: String) { persisted[key] = value }
    func showHUD(_ type: SneakContentType, value: Double) { huds.append((type, value)) }
    func adjustBuiltinBrightness(delta: Float) { builtinDeltas.append(delta) }
    func adjustSystemVolume(up: Bool, fine: Bool) { systemVolume.append((up, fine)) }
    func toggleSystemMute() { systemMuteToggles += 1 }
}

@MainActor
final class DisplayControlRouterTests: XCTestCase {
    private var env: FakeEnvironment!
    private var router: DisplayControlRouter!
    private var display: ExternalDisplay!
    private var brightnessWriter: FakeWriter!
    private var volumeWriter: FakeWriter!

    override func setUp() async throws {
        env = FakeEnvironment()
        router = DisplayControlRouter(environment: env)
        brightnessWriter = FakeWriter()
        volumeWriter = FakeWriter()
        display = ExternalDisplay(id: 2, uuid: "UUID-2", name: "DELL S2421H",
                                  brightnessWriter: brightnessWriter, volumeWriter: volumeWriter,
                                  brightness: 0.5, volume: 0.4, softwareLevel: 1)
        env.displays = [display]
        env.cursorDisplay = 2
        env.output = AudioOutputInfo(name: "DELL S2421H", isDisplayAudio: true)
    }

    // MARK: Brightness

    func testBrightnessUpWritesDDCAndShowsHUD() {
        router.perform(.brightnessUp, fine: false)
        XCTAssertEqual(display.brightness, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(brightnessWriter.values, [56])
        XCTAssertEqual(env.huds.last?.type, .brightness)
        XCTAssertEqual(env.huds.last?.value ?? -1, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(env.persisted["UUID-2.brightness"] ?? -1, 0.5625, accuracy: 1e-9)
    }

    func testFineStep() {
        router.perform(.brightnessUp, fine: true)
        XCTAssertEqual(brightnessWriter.values, [52]) // 0.515625 * 100
    }

    func testBrightnessClampsAtBounds() {
        display.brightness = 1
        router.perform(.brightnessUp, fine: false)
        XCTAssertEqual(brightnessWriter.values, [100])
        display.brightness = 0.03
        router.perform(.brightnessDown, fine: false)
        XCTAssertEqual(brightnessWriter.values.last, 0)
        XCTAssertEqual(display.brightness, 0)
    }

    func testCursorOnBuiltinUsesBrightnessManagerPath() {
        env.cursorDisplay = 1
        router.perform(.brightnessDown, fine: false)
        XCTAssertEqual(env.builtinDeltas, [-0.0625])
        XCTAssertTrue(brightnessWriter.values.isEmpty)
    }

    func testNoCursorDisplayUsesBuiltinPath() {
        env.cursorDisplay = nil
        router.perform(.brightnessUp, fine: false)
        XCTAssertEqual(env.builtinDeltas, [0.0625])
    }

    func testThreeFailuresSwitchToGamma() {
        for _ in 0..<ExternalDisplay.failureThreshold { display.recordWriteResult(false) }
        XCTAssertFalse(display.ddcAvailable)

        router.perform(.brightnessDown, fine: false)
        XCTAssertEqual(env.gamma.last?.id, 2)
        XCTAssertEqual(env.gamma.last?.level ?? -1, 0.9375, accuracy: 1e-9)
        XCTAssertEqual(env.persisted["UUID-2.software"] ?? -1, 0.9375, accuracy: 1e-9)
        XCTAssertEqual(env.huds.last?.type, .brightness)
        XCTAssertTrue(brightnessWriter.values.isEmpty)
    }

    func testSuccessResetsFailureCount() {
        display.recordWriteResult(false)
        display.recordWriteResult(false)
        display.recordWriteResult(true)
        display.recordWriteResult(false)
        XCTAssertTrue(display.ddcAvailable)
    }

    func testDisplayWithoutDDCUsesGammaImmediately() {
        let noDDC = ExternalDisplay(id: 3, uuid: "UUID-3", name: "TV", brightnessWriter: nil, volumeWriter: nil,
                                    brightness: 0.5, volume: 0.5, softwareLevel: 1)
        env.displays = [noDDC]
        env.cursorDisplay = 3
        router.perform(.brightnessDown, fine: false)
        XCTAssertEqual(env.gamma.last?.id, 3)
    }

    // MARK: Volume

    func testVolumeUpOnMonitorAudioWritesDDC() {
        env.output = AudioOutputInfo(name: " dell s2421h ", isDisplayAudio: true)
        router.perform(.volumeUp, fine: false)
        XCTAssertEqual(volumeWriter.values, [46]) // 0.4625
        XCTAssertEqual(env.huds.last?.type, .volume)
        XCTAssertTrue(env.systemVolume.isEmpty)
    }

    func testVolumeOnBluetoothUsesSystemVolume() {
        env.output = AudioOutputInfo(name: "ULT WEAR", isDisplayAudio: false)
        router.perform(.volumeDown, fine: true)
        XCTAssertEqual(env.systemVolume.count, 1)
        XCTAssertEqual(env.systemVolume.first?.up, false)
        XCTAssertEqual(env.systemVolume.first?.fine, true)
        XCTAssertTrue(volumeWriter.values.isEmpty)
    }

    func testVolumeOnUnmatchedHDMIUsesSystemVolume() {
        env.output = AudioOutputInfo(name: "LG TV", isDisplayAudio: true)
        router.perform(.volumeUp, fine: false)
        XCTAssertEqual(env.systemVolume.count, 1)
    }

    func testVolumeWhenMonitorHasNoDDCUsesSystemVolume() {
        for _ in 0..<ExternalDisplay.failureThreshold { display.recordWriteResult(false) }
        router.perform(.volumeUp, fine: false)
        XCTAssertEqual(env.systemVolume.count, 1)
    }

    func testMuteAndUnmuteMonitor() {
        router.perform(.volumeMute, fine: false)
        XCTAssertEqual(volumeWriter.values, [0])
        XCTAssertEqual(env.huds.last?.value, 0)

        router.perform(.volumeMute, fine: false)
        XCTAssertEqual(volumeWriter.values, [0, 40])
        XCTAssertEqual(env.huds.last?.value ?? -1, 0.4, accuracy: 1e-9)
    }

    func testMuteAtZeroUnmutesToFallback() {
        display.volume = 0
        router.perform(.volumeMute, fine: false)
        router.perform(.volumeMute, fine: false)
        XCTAssertEqual(volumeWriter.values.last, 25)
    }

    func testVolumeUpWhileMutedRestoresThenSteps() {
        router.perform(.volumeMute, fine: false)
        router.perform(.volumeUp, fine: false)
        XCTAssertEqual(volumeWriter.values, [0, 46])
        XCTAssertNil(display.volumeBeforeMute)
    }

    func testMuteOnNonMonitorOutputTogglesSystemMute() {
        env.output = nil
        router.perform(.volumeMute, fine: false)
        XCTAssertEqual(env.systemMuteToggles, 1)
    }

    // MARK: Media-key claims

    func testClaimsMediaKeys() {
        XCTAssertTrue(router.claimsMediaKey(.brightnessUp))
        XCTAssertTrue(router.claimsMediaKey(.volumeUp))

        env.cursorDisplay = 1
        env.output = AudioOutputInfo(name: "MacBook Pro Speakers", isDisplayAudio: false)
        XCTAssertFalse(router.claimsMediaKey(.brightnessUp))
        XCTAssertFalse(router.claimsMediaKey(.volumeMute))
    }

    // MARK: ExternalDisplay

    func testInitialReadingsRespectUserChanges() {
        router.perform(.brightnessUp, fine: false)
        display.applyInitialReadings(brightness: DDCReading(current: 20, max: 200), volume: DDCReading(current: 30, max: 100))
        XCTAssertEqual(display.brightness, 0.5625, accuracy: 1e-9, "user already pressed a key — keep their value")
        XCTAssertEqual(display.brightnessMax, 200)
        XCTAssertEqual(display.volume, 0.3, accuracy: 1e-9)
    }

    func testStatusLabel() {
        XCTAssertEqual(display.statusLabel(hasSpeakers: true), "DDC + speakers")
        XCTAssertEqual(display.statusLabel(hasSpeakers: false), "DDC")
        for _ in 0..<ExternalDisplay.failureThreshold { display.recordWriteResult(false) }
        XCTAssertEqual(display.statusLabel(hasSpeakers: true), "Software dimming")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Create the three source files containing only `import AppKit`, then:
Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DisplayControlRouterTests 2>&1 | tail -20`
Expected: build FAILS with `cannot find type 'DisplayControlEnvironment' in scope`.

- [ ] **Step 3: Implement** — `Brow/Managers/DisplayControl/AudioOutput.swift`

```swift
//
//  AudioOutput.swift
//  Brow
//

import Foundation

struct AudioOutputInfo: Equatable {
    let name: String
    /// HDMI or DisplayPort transport — audio carried to a monitor.
    let isDisplayAudio: Bool
}
```

- [ ] **Step 4: Implement** — `Brow/Managers/DisplayControl/ExternalDisplay.swift`

```swift
//
//  ExternalDisplay.swift
//  Brow
//
//  Per-monitor state for external display control. Mutated on the main
//  actor only; DDC writes go through the writers on the DDC queue.
//

import CoreGraphics

@MainActor
final class ExternalDisplay: Identifiable {
    enum LevelKind: String {
        case brightness, volume, software
    }

    static let failureThreshold = 3

    nonisolated let id: CGDirectDisplayID
    let uuid: String
    let name: String
    let brightnessWriter: LevelWriter?
    let volumeWriter: LevelWriter?

    var brightness: Double
    var volume: Double
    var softwareLevel: Double
    var volumeBeforeMute: Double?
    var brightnessMax: UInt16 = 100
    var volumeMax: UInt16 = 100
    var brightnessTouched = false
    var volumeTouched = false

    private(set) var ddcAvailable: Bool
    private var consecutiveFailures = 0

    init(id: CGDirectDisplayID, uuid: String, name: String,
         brightnessWriter: LevelWriter?, volumeWriter: LevelWriter?,
         brightness: Double, volume: Double, softwareLevel: Double) {
        self.id = id
        self.uuid = uuid
        self.name = name
        self.brightnessWriter = brightnessWriter
        self.volumeWriter = volumeWriter
        self.brightness = brightness
        self.volume = volume
        self.softwareLevel = softwareLevel
        self.ddcAvailable = brightnessWriter != nil
    }

    func recordWriteResult(_ ok: Bool) {
        if ok {
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        if consecutiveFailures >= Self.failureThreshold {
            ddcAvailable = false
        }
    }

    /// First DDC read after (re)connecting. Values the user already changed win.
    func applyInitialReadings(brightness b: DDCReading?, volume v: DDCReading?) {
        if let b {
            brightnessMax = b.max
            if !brightnessTouched { brightness = Double(b.current) / Double(b.max) }
        }
        if let v {
            volumeMax = v.max
            if !volumeTouched { volume = Double(v.current) / Double(v.max) }
        }
    }

    func levelKey(_ kind: LevelKind) -> String {
        Self.levelKey(uuid: uuid, kind: kind)
    }

    static func levelKey(uuid: String, kind: LevelKind) -> String {
        "\(uuid).\(kind.rawValue)"
    }

    /// CoreAudio names HDMI/DP audio after the EDID product name, which is
    /// also `NSScreen.localizedName` — compare case- and whitespace-insensitively.
    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func statusLabel(hasSpeakers: Bool) -> String {
        guard ddcAvailable else { return "Software dimming" }
        return hasSpeakers && volumeWriter != nil ? "DDC + speakers" : "DDC"
    }
}
```

- [ ] **Step 5: Implement** — `Brow/Managers/DisplayControl/DisplayControlRouter.swift`

```swift
//
//  DisplayControlRouter.swift
//  Brow
//
//  Decides where a brightness/volume key goes: built-in display
//  (BrightnessManager), external DDC, gamma fallback, or system audio
//  (VolumeManager). Hardware access lives behind DisplayControlEnvironment.
//

import CoreGraphics

@MainActor
protocol DisplayControlEnvironment: AnyObject {
    func displayUnderCursor() -> CGDirectDisplayID?
    func externalDisplays() -> [ExternalDisplay]
    func defaultAudioOutput() -> AudioOutputInfo?
    func applyGamma(level: Double, to displayID: CGDirectDisplayID)
    func persistLevel(_ value: Double, key: String)
    func showHUD(_ type: SneakContentType, value: Double)
    func adjustBuiltinBrightness(delta: Float)
    func adjustSystemVolume(up: Bool, fine: Bool)
    func toggleSystemMute()
}

@MainActor
final class DisplayControlRouter {
    static let step = 1.0 / 16.0
    static let fineStep = 1.0 / 64.0
    static let unmuteFallbackVolume = 0.25

    private unowned let env: DisplayControlEnvironment

    init(environment: DisplayControlEnvironment) {
        self.env = environment
    }

    /// Whether an NX media key should be taken away from macOS.
    func claimsMediaKey(_ action: DisplayKeyAction) -> Bool {
        switch action {
        case .brightnessDown, .brightnessUp: cursorDisplay() != nil
        case .volumeMute, .volumeDown, .volumeUp: speakerDisplay() != nil
        }
    }

    func perform(_ action: DisplayKeyAction, fine: Bool) {
        let step = fine ? Self.fineStep : Self.step
        switch action {
        case .brightnessUp: adjustBrightness(delta: step)
        case .brightnessDown: adjustBrightness(delta: -step)
        case .volumeUp: adjustVolume(delta: step, up: true, fine: fine)
        case .volumeDown: adjustVolume(delta: -step, up: false, fine: fine)
        case .volumeMute: toggleMute()
        }
    }

    // MARK: - Targets

    private func cursorDisplay() -> ExternalDisplay? {
        guard let id = env.displayUnderCursor() else { return nil }
        return env.externalDisplays().first { $0.id == id }
    }

    /// The monitor whose speakers are the current default output, if we can drive them.
    private func speakerDisplay() -> ExternalDisplay? {
        guard let output = env.defaultAudioOutput(), output.isDisplayAudio else { return nil }
        let name = ExternalDisplay.normalizedName(output.name)
        return env.externalDisplays().first {
            $0.ddcAvailable && $0.volumeWriter != nil && ExternalDisplay.normalizedName($0.name) == name
        }
    }

    // MARK: - Brightness

    private func adjustBrightness(delta: Double) {
        guard let display = cursorDisplay() else {
            env.adjustBuiltinBrightness(delta: Float(delta))
            return
        }
        if display.ddcAvailable, let writer = display.brightnessWriter {
            display.brightness = clamp(display.brightness + delta)
            display.brightnessTouched = true
            writer.submit(Self.ddcValue(display.brightness, max: display.brightnessMax))
            env.persistLevel(display.brightness, key: display.levelKey(.brightness))
            env.showHUD(.brightness, value: display.brightness)
        } else {
            display.softwareLevel = clamp(display.softwareLevel + delta)
            env.applyGamma(level: display.softwareLevel, to: display.id)
            env.persistLevel(display.softwareLevel, key: display.levelKey(.software))
            env.showHUD(.brightness, value: display.softwareLevel)
        }
    }

    // MARK: - Volume

    private func adjustVolume(delta: Double, up: Bool, fine: Bool) {
        guard let display = speakerDisplay(), let writer = display.volumeWriter else {
            env.adjustSystemVolume(up: up, fine: fine)
            return
        }
        if let restored = display.volumeBeforeMute {
            display.volume = restored
            display.volumeBeforeMute = nil
        }
        setVolume(clamp(display.volume + delta), on: display, writer: writer)
    }

    private func toggleMute() {
        guard let display = speakerDisplay(), let writer = display.volumeWriter else {
            env.toggleSystemMute()
            return
        }
        if let restored = display.volumeBeforeMute {
            display.volumeBeforeMute = nil
            setVolume(restored, on: display, writer: writer)
        } else {
            // VCP 0x8D mute is rarely implemented — remember the level and write 0.
            display.volumeBeforeMute = display.volume > 0 ? display.volume : Self.unmuteFallbackVolume
            display.volume = 0
            display.volumeTouched = true
            writer.submit(0)
            env.showHUD(.volume, value: 0)
        }
    }

    private func setVolume(_ value: Double, on display: ExternalDisplay, writer: LevelWriter) {
        display.volume = value
        display.volumeTouched = true
        writer.submit(Self.ddcValue(value, max: display.volumeMax))
        env.persistLevel(value, key: display.levelKey(.volume))
        env.showHUD(.volume, value: value)
    }

    // MARK: - Helpers

    static func ddcValue(_ level: Double, max: UInt16) -> UInt16 {
        UInt16((level * Double(max)).rounded())
    }

    private func clamp(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
```

- [ ] **Step 6: Run test to verify it passes**

Run: `xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests/DisplayControlRouterTests 2>&1 | tail -20`
Expected: `** TEST SUCCEEDED **`, 19 tests passed.

- [ ] **Step 7: Commit**

```bash
git add Brow/Managers/DisplayControl/ExternalDisplay.swift Brow/Managers/DisplayControl/AudioOutput.swift Brow/Managers/DisplayControl/DisplayControlRouter.swift BrowTests/DisplayControlRouterTests.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): route brightness/volume keys to DDC, gamma or system

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Hardware layer — IOAVService transport, registry, CoreAudio, DisplayControlCenter

No unit tests (real IOKit/CoreAudio); verified by build + running the app on the target hardware.

**Files:**
- Create: `Brow/Managers/DisplayControl/DDC/Arm64DDCTransport.swift`
- Create: `Brow/Managers/DisplayControl/DisplayRegistry.swift`
- Modify: `Brow/Managers/DisplayControl/AudioOutput.swift` (append `CoreAudioOutputs`)
- Create: `Brow/Managers/DisplayControl/DisplayControlCenter.swift`
- Modify: `Brow/models/Constants.swift` (Defaults keys, `// MARK: HUD` block ~line 202)
- Modify: `Brow/BrowViewCoordinator.swift` (start center at launch), `Brow/BrowApp.swift:79` (stop on terminate)

**Interfaces:**
- Consumes: everything from Tasks 1–6.
- Produces:
  - `Defaults.Keys.externalDisplayControl: Key<Bool>` (default `true`), `Defaults.Keys.externalDisplayLevels: Key<[String: Double]>` (default `[:]`)
  - `final class Arm64DDCTransport: DDCTransport { typealias CreateFn; static let createService: CreateFn?; init(retainedService: UnsafeMutableRawPointer) }`
  - `enum DisplayRegistry { static func externalDisplayIDs() -> [CGDirectDisplayID]; static func match(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: Arm64DDCTransport] }`
  - `enum CoreAudioOutputs { static func defaultOutput() -> AudioOutputInfo?; static func displayAudioDeviceNames() -> [String] }`
  - `@MainActor final class DisplayControlCenter: ObservableObject, DisplayControlEnvironment { static let shared; @Published private(set) var displays: [ExternalDisplay]; @Published private(set) var displayAudioNames: Set<String>; lazy var router: DisplayControlRouter; func start(); func stop() }`

- [ ] **Step 1: Defaults keys** — in `Brow/models/Constants.swift`, after the `optionKeyAction` line in `// MARK: HUD`:

```swift
    // External display brightness/volume keys (DDC/CI)
    static let externalDisplayControl = Key<Bool>("externalDisplayControl", default: true)
    /// "<displayUUID>.brightness" | ".volume" | ".software" → 0…1
    static let externalDisplayLevels = Key<[String: Double]>("externalDisplayLevels", default: [:])
```

- [ ] **Step 2: Transport** — `Brow/Managers/DisplayControl/DDC/Arm64DDCTransport.swift`

```swift
//
//  Arm64DDCTransport.swift
//  Brow
//
//  I2C over Apple Silicon's private IOAVService API (same calls as
//  MonitorControl's Arm64DDC, MIT). Symbols are resolved at runtime; if
//  they are missing (Intel, future macOS) no transport is created and the
//  display falls back to gamma dimming.
//

import Foundation
import IOKit

final class Arm64DDCTransport: DDCTransport {
    typealias CreateFn = @convention(c) (UnsafeRawPointer?, io_service_t) -> UnsafeMutableRawPointer?
    private typealias I2CFn = @convention(c) (UnsafeMutableRawPointer, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    static let createService: CreateFn? = symbol("IOAVServiceCreateWithService")
    private static let writeI2C: I2CFn? = symbol("IOAVServiceWriteI2C")
    private static let readI2C: I2CFn? = symbol("IOAVServiceReadI2C")

    static var isSupported: Bool { createService != nil && writeI2C != nil && readI2C != nil }

    private static let chipAddress: UInt32 = 0x37
    private static let dataAddress: UInt32 = 0x51

    private let service: UnsafeMutableRawPointer

    /// Takes ownership of a +1 IOAVService reference.
    init(retainedService: UnsafeMutableRawPointer) {
        service = retainedService
    }

    deinit {
        Unmanaged<AnyObject>.fromOpaque(service).release()
    }

    func write(_ packet: [UInt8]) -> Bool {
        guard let writeI2C = Self.writeI2C else { return false }
        var bytes = packet
        let result = bytes.withUnsafeMutableBytes { buffer in
            writeI2C(service, Self.chipAddress, Self.dataAddress, buffer.baseAddress!, UInt32(buffer.count))
        }
        return result == kIOReturnSuccess
    }

    func read(count: Int) -> [UInt8]? {
        guard let readI2C = Self.readI2C else { return nil }
        var bytes = [UInt8](repeating: 0, count: count)
        let result = bytes.withUnsafeMutableBytes { buffer in
            readI2C(service, Self.chipAddress, 0, buffer.baseAddress!, UInt32(buffer.count))
        }
        return result == kIOReturnSuccess ? bytes : nil
    }

    private static func symbol<T>(_ name: String) -> T? {
        // RTLD_DEFAULT — IOKit is already linked into the process.
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return nil }
        return unsafeBitCast(sym, to: T.self)
    }
}
```

- [ ] **Step 3: Registry** — `Brow/Managers/DisplayControl/DisplayRegistry.swift`

```swift
//
//  DisplayRegistry.swift
//  Brow
//
//  Matches online external CGDisplays to the DCPAVServiceProxy IORegistry
//  entries that carry their DDC/CI channel. Ported from MonitorControl's
//  `Arm64DDC.getServiceMatches` / `ioregMatchScore` (MIT): framebuffer
//  entries (AppleCLCD2 / IOMobileFramebufferShim) describe the panel, the
//  DCPAVServiceProxy that follows them is its I2C service.
//

import CoreGraphics
import Foundation
import IOKit

enum DisplayRegistry {
    private struct Candidate {
        var edidUUID = ""
        var productName = ""
        var serialNumber: Int64 = 0
        var ioDisplayLocation = ""
        var serviceLocation = 0
        var service: UnsafeMutableRawPointer?
    }

    private static let framebufferNames: Set<String> = ["AppleCLCD2", "IOMobileFramebufferShim"]
    private static let avServiceProxyName = "DCPAVServiceProxy"

    private typealias CoreDisplayInfoFn = @convention(c) (CGDirectDisplayID) -> UnsafeMutableRawPointer?
    private static let coreDisplayInfo: CoreDisplayInfoFn? = {
        guard let handle = dlopen("/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY),
              let sym = dlsym(handle, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(sym, to: CoreDisplayInfoFn.self)
    }()

    static func externalDisplayIDs() -> [CGDirectDisplayID] {
        var ids = [CGDirectDisplayID](repeating: 0, count: 16)
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(UInt32(ids.count), &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).filter { CGDisplayIsBuiltin($0) == 0 }
    }

    static func match(displayIDs: [CGDirectDisplayID]) -> [CGDirectDisplayID: Arm64DDCTransport] {
        guard Arm64DDCTransport.isSupported else { return [:] }
        let candidates = ioregCandidates()
        defer { candidates.forEach { if let s = $0.service { Unmanaged<AnyObject>.fromOpaque(s).release() } } }

        var scored: [(score: Int, order: Int, displayID: CGDirectDisplayID, candidate: Candidate)] = []
        for displayID in displayIDs {
            for candidate in candidates where candidate.service != nil {
                scored.append((matchScore(displayID: displayID, candidate: candidate), scored.count, displayID, candidate))
            }
        }
        scored.sort { $0.score != $1.score ? $0.score > $1.score : $0.order < $1.order }

        var takenDisplays = Set<CGDirectDisplayID>()
        var takenLocations = Set<Int>()
        var result: [CGDirectDisplayID: Arm64DDCTransport] = [:]
        for entry in scored where entry.score > 0
            && !takenDisplays.contains(entry.displayID)
            && !takenLocations.contains(entry.candidate.serviceLocation) {
            takenDisplays.insert(entry.displayID)
            takenLocations.insert(entry.candidate.serviceLocation)
            let retained = Unmanaged<AnyObject>.fromOpaque(entry.candidate.service!).retain().toOpaque()
            result[entry.displayID] = Arm64DDCTransport(retainedService: retained)
        }
        return result
    }

    // MARK: - IORegistry walk

    private static func ioregCandidates() -> [Candidate] {
        var result: [Candidate] = []
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        var iterator = io_iterator_t()
        guard IORegistryEntryCreateIterator(root, kIOServicePlane, IOOptionBits(kIORegistryIterateRecursively), &iterator) == KERN_SUCCESS else {
            return result
        }
        defer { IOObjectRelease(iterator) }

        let nameBuffer = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_name_t>.size)
        defer { nameBuffer.deallocate() }

        var current = Candidate()
        var serviceLocation = 0
        while case let entry = IOIteratorNext(iterator), entry != IO_OBJECT_NULL {
            defer { IOObjectRelease(entry) }
            guard IORegistryEntryGetName(entry, nameBuffer) == KERN_SUCCESS else { continue }
            let name = String(cString: nameBuffer)

            if framebufferNames.contains(name) {
                current = framebufferCandidate(entry)
                serviceLocation += 1
                current.serviceLocation = serviceLocation
            } else if name == avServiceProxyName {
                var candidate = current
                candidate.service = nil
                if property(entry, "Location") as? String == "External" {
                    candidate.service = Arm64DDCTransport.createService?(nil, entry)
                }
                result.append(candidate)
            }
        }
        return result
    }

    private static func framebufferCandidate(_ entry: io_registry_entry_t) -> Candidate {
        var candidate = Candidate()
        candidate.edidUUID = property(entry, "EDID UUID") as? String ?? ""
        let path = UnsafeMutablePointer<CChar>.allocate(capacity: MemoryLayout<io_string_t>.size)
        defer { path.deallocate() }
        if IORegistryEntryGetPath(entry, kIOServicePlane, path) == KERN_SUCCESS {
            candidate.ioDisplayLocation = String(cString: path)
        }
        if let attributes = property(entry, "DisplayAttributes") as? NSDictionary,
           let product = attributes["ProductAttributes"] as? NSDictionary {
            candidate.productName = product["ProductName"] as? String ?? ""
            candidate.serialNumber = (product["SerialNumber"] as? NSNumber)?.int64Value ?? 0
        }
        return candidate
    }

    private static func property(_ entry: io_registry_entry_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    // MARK: - Scoring (MonitorControl `ioregMatchScore`)

    private static func matchScore(displayID: CGDirectDisplayID, candidate: Candidate) -> Int {
        guard let coreDisplayInfo, let raw = coreDisplayInfo(displayID) else { return 0 }
        let info = Unmanaged<CFDictionary>.fromOpaque(raw).takeRetainedValue() as NSDictionary
        var score = 0

        func int64(_ key: String) -> Int64? { (info[key] as? NSNumber)?.int64Value }
        func hex2(_ v: Int64) -> String { String(format: "%02X", UInt8(clamping: v)) }

        if let year = int64(kDisplayYearOfManufacture), let week = int64(kDisplayWeekOfManufacture),
           let vendor = int64(kDisplayVendorID), let product = int64(kDisplayProductID),
           let vSize = int64(kDisplayVerticalImageSize), let hSize = int64(kDisplayHorizontalImageSize) {
            let productID = UInt16(clamping: product)
            let keys: [(key: String, location: Int)] = [
                (String(format: "%04X", UInt16(clamping: vendor)), 0),
                (hex2(Int64(productID & 0xFF)) + hex2(Int64(productID >> 8)), 4),
                (hex2(week) + hex2(year - 1990), 19),
                (hex2(hSize / 10) + hex2(vSize / 10), 30),
            ]
            for (key, location) in keys where key != "0000"
                && key == String(candidate.edidUUID.prefix(location + 4).suffix(4)) {
                score += 1
            }
        }
        if !candidate.ioDisplayLocation.isEmpty,
           let location = info[kIODisplayLocationKey] as? String, location == candidate.ioDisplayLocation {
            score += 10
        }
        if !candidate.productName.isEmpty,
           let names = info["DisplayProductName"] as? [String: String],
           let name = names["en_US"] ?? names.first?.value,
           name.lowercased() == candidate.productName.lowercased() {
            score += 1
        }
        if candidate.serialNumber != 0, let serial = int64(kDisplaySerialNumber), serial == candidate.serialNumber {
            score += 1
        }
        return score
    }
}
```

- [ ] **Step 4: CoreAudio** — append to `Brow/Managers/DisplayControl/AudioOutput.swift` (add `import CoreAudio` at the top):

```swift
enum CoreAudioOutputs {
    static func defaultOutput() -> AudioOutputInfo? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        return info(for: deviceID)
    }

    /// Names of every HDMI/DisplayPort audio device (for the Settings status column).
    static func displayAudioDeviceNames() -> [String] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap(info(for:)).filter(\.isDisplayAudio).map(\.name)
    }

    private static func info(for deviceID: AudioObjectID) -> AudioOutputInfo? {
        var nameAddress = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &name) {
            AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &size, $0)
        }
        guard status == noErr, let cfName = name?.takeRetainedValue() else { return nil }

        var transportAddress = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var transport: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(deviceID, &transportAddress, 0, nil, &size, &transport)

        return AudioOutputInfo(
            name: cfName as String,
            isDisplayAudio: transport == kAudioDeviceTransportTypeHDMI || transport == kAudioDeviceTransportTypeDisplayPort
        )
    }
}
```

- [ ] **Step 5: Center** — `Brow/Managers/DisplayControl/DisplayControlCenter.swift`

```swift
//
//  DisplayControlCenter.swift
//  Brow
//
//  Owns the external-display list, rebuilds it on hot-plug and wake, and is
//  the production DisplayControlEnvironment for the router.
//

import AppKit
import Combine
import Defaults

/// C callback — a nonisolated free function, since C function pointers
/// cannot carry actor isolation.
private func displayReconfigured(_ display: CGDirectDisplayID, _ flags: CGDisplayChangeSummaryFlags, _ userInfo: UnsafeMutableRawPointer?) {
    guard !flags.contains(.beginConfigurationFlag) else { return }
    DispatchQueue.main.async {
        MainActor.assumeIsolated { DisplayControlCenter.shared.scheduleRebuild(after: 1) }
    }
}

@MainActor
final class DisplayControlCenter: ObservableObject, DisplayControlEnvironment {
    static let shared = DisplayControlCenter()

    @Published private(set) var displays: [ExternalDisplay] = []
    /// Normalised names of HDMI/DP audio devices, for the Settings status column.
    @Published private(set) var displayAudioNames: Set<String> = []

    private(set) lazy var router = DisplayControlRouter(environment: self)

    private let dimmer = GammaDimmer(applier: CoreGraphicsGammaApplier())
    private let ddcQueue = DispatchQueue(label: "Brow.DisplayControl.DDC", qos: .userInitiated)
    private var isRunning = false
    private var rebuildGeneration = 0
    private var rebuildWorkItem: DispatchWorkItem?
    private var wakeObserver: NSObjectProtocol?

    private init() {}

    // MARK: - Lifecycle

    func start() {
        guard !isRunning else { return }
        isRunning = true
        CGDisplayRegisterReconfigurationCallback(displayReconfigured, nil)
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { _ in
            // IOAVService handles go stale across sleep; the bus needs a moment after wake.
            MainActor.assumeIsolated { DisplayControlCenter.shared.scheduleRebuild(after: 2) }
        }
        rebuild()
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        CGDisplayRemoveReconfigurationCallback(displayReconfigured, nil)
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        wakeObserver = nil
        rebuildWorkItem?.cancel()
        dimmer.restoreAll()
        displays = []
    }

    func scheduleRebuild(after delay: TimeInterval) {
        guard isRunning else { return }
        rebuildWorkItem?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { DisplayControlCenter.shared.rebuild() } }
        rebuildWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func rebuild() {
        rebuildGeneration &+= 1
        let generation = rebuildGeneration
        ddcQueue.async {
            let ids = DisplayRegistry.externalDisplayIDs()
            let matches = DisplayRegistry.match(displayIDs: ids)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let center = DisplayControlCenter.shared
                    guard center.isRunning, center.rebuildGeneration == generation else { return }
                    center.install(displayIDs: ids, matches: matches)
                }
            }
        }
    }

    private func install(displayIDs: [CGDirectDisplayID], matches: [CGDirectDisplayID: Arm64DDCTransport]) {
        dimmer.restoreAll()
        let levels = Defaults[.externalDisplayLevels]
        let queue = ddcQueue

        displays = displayIDs.map { id in
            let uuid = Self.uuid(for: id)
            let channel = matches[id].map { DDCChannel(transport: $0) }
            let brightnessWriter = channel.map { DDCWriteCoalescer(vcp: DDCVCP.brightness, channel: $0, executor: { queue.async(execute: $0) }) }
            let volumeWriter = channel.map { DDCWriteCoalescer(vcp: DDCVCP.volume, channel: $0, executor: { queue.async(execute: $0) }) }

            let display = ExternalDisplay(
                id: id, uuid: uuid, name: Self.name(for: id),
                brightnessWriter: brightnessWriter, volumeWriter: volumeWriter,
                brightness: levels[ExternalDisplay.levelKey(uuid: uuid, kind: .brightness)] ?? 0.5,
                volume: levels[ExternalDisplay.levelKey(uuid: uuid, kind: .volume)] ?? 0.5,
                softwareLevel: levels[ExternalDisplay.levelKey(uuid: uuid, kind: .software)] ?? 1
            )
            for writer in [brightnessWriter, volumeWriter].compactMap({ $0 }) {
                writer.onResult = { [weak display] ok in
                    DispatchQueue.main.async {
                        MainActor.assumeIsolated {
                            display?.recordWriteResult(ok)
                            DisplayControlCenter.shared.objectWillChange.send()
                        }
                    }
                }
            }
            if !display.ddcAvailable && display.softwareLevel < 1 {
                dimmer.setLevel(display.softwareLevel, for: id)
            }
            if let channel {
                readInitialLevels(of: display, over: channel)
            }
            return display
        }
        displayAudioNames = Set(CoreAudioOutputs.displayAudioDeviceNames().map(ExternalDisplay.normalizedName))
        Logger.log(
            "DisplayControl: " + displays.map { "\($0.name) [\($0.ddcAvailable ? "ddc" : "gamma")]" }.joined(separator: ", "),
            category: .debug
        )
    }

    private func readInitialLevels(of display: ExternalDisplay, over channel: DDCChannel) {
        let name = display.name
        ddcQueue.async { [weak display] in
            let brightness = channel.read(vcp: DDCVCP.brightness)
            let volume = channel.read(vcp: DDCVCP.volume)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    display?.applyInitialReadings(brightness: brightness, volume: volume)
                    Logger.log("DisplayControl: \(name) brightness=\(String(describing: brightness)) volume=\(String(describing: volume))", category: .debug)
                }
            }
        }
    }

    // MARK: - Display identity

    private static func uuid(for id: CGDirectDisplayID) -> String {
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id) else { return "\(id)" }
        return CFUUIDCreateString(nil, uuid.takeRetainedValue()) as String
    }

    private static func name(for id: CGDirectDisplayID) -> String {
        NSScreen.screens.first { screenNumber($0) == id }?.localizedName ?? "Display \(id)"
    }

    private static func screenNumber(_ screen: NSScreen) -> CGDirectDisplayID? {
        (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
    }

    // MARK: - DisplayControlEnvironment

    func displayUnderCursor() -> CGDirectDisplayID? {
        let location = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }.flatMap(Self.screenNumber)
    }

    func externalDisplays() -> [ExternalDisplay] { displays }

    func defaultAudioOutput() -> AudioOutputInfo? { CoreAudioOutputs.defaultOutput() }

    func applyGamma(level: Double, to displayID: CGDirectDisplayID) {
        dimmer.setLevel(level, for: displayID)
    }

    func persistLevel(_ value: Double, key: String) {
        Defaults[.externalDisplayLevels][key] = value
    }

    func showHUD(_ type: SneakContentType, value: Double) {
        BrowViewCoordinator.shared.toggleSneakPeek(status: true, type: type, value: CGFloat(value), force: true)
    }

    func adjustBuiltinBrightness(delta: Float) {
        BrightnessManager.shared.setRelative(delta: delta)
    }

    func adjustSystemVolume(up: Bool, fine: Bool) {
        let divisor: Float = fine ? 4 : 1
        if up {
            VolumeManager.shared.increase(stepDivisor: divisor)
        } else {
            VolumeManager.shared.decrease(stepDivisor: divisor)
        }
    }

    func toggleSystemMute() {
        VolumeManager.shared.toggleMuteAction()
    }
}
```

- [ ] **Step 6: `force` flag on the HUD** — `Brow/BrowViewCoordinator.swift:256`. macOS shows no OSD for DDC changes, so external-display HUDs are shown even when "Replace system HUD" is off:

```swift
    func toggleSneakPeek(
        status: Bool, type: SneakContentType, duration: TimeInterval = 1.5, value: CGFloat = 0,
        icon: String = "", force: Bool = false
    ) {
        sneakPeekDuration = duration
        if type != .music {
            // close()
            if !Defaults[.hudReplacement] && !force {
                return
            }
        }
```

(Only the signature and the inner `if` change; the rest of the function stays as is.)

- [ ] **Step 7: Start/stop the center** —

In `Brow/BrowViewCoordinator.swift`, inside the launch `Task { @MainActor in … }` in `init` (after the `if Defaults[.hudReplacement] { … }` block), add:

```swift
            if Defaults[.externalDisplayControl] {
                DisplayControlCenter.shared.start()
            }
```

In `Brow/BrowApp.swift` `applicationWillTerminate(_:)`, after `XPCHelperClient.shared.stopMonitoringAccessibilityAuthorization()`:

```swift
        MainActor.assumeIsolated { DisplayControlCenter.shared.stop() } // restores gamma if we dimmed
```

- [ ] **Step 8: Register + build + full test run**

Run: `ruby tools/xcodeproj/add_display_control_files.rb && xcodebuild -scheme Brow -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5 && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **` then `** TEST SUCCEEDED **`.

- [ ] **Step 9: Hardware smoke test**

```bash
osascript -e 'quit app "Brow"' 2>/dev/null
APP=$(xcodebuild -scheme Brow -configuration Debug -showBuildSettings 2>/dev/null | awk '/ BUILT_PRODUCTS_DIR /{print $3}')/Brow.app
"$APP/Contents/MacOS/Brow" 2>&1 | grep --line-buffered DisplayControl
```

Expected within ~3 s (Ctrl-C afterwards):
```
… DisplayControl: DELL P2419HC [ddc], DELL S2421H [ddc]
… DisplayControl: DELL P2419HC brightness=Optional(Brow.DDCReading(current: …, max: 100)) volume=…
… DisplayControl: DELL S2421H brightness=Optional(…) volume=Optional(…)
```
If a monitor shows `[gamma]` or `brightness=nil`, check "DDC/CI" is enabled in that Dell's OSD (Others → DDC/CI) before continuing. Record the result in the task report.

- [ ] **Step 10: Commit**

```bash
git add Brow/Managers/DisplayControl Brow/models/Constants.swift Brow/BrowViewCoordinator.swift Brow/BrowApp.swift Brow.xcodeproj/project.pbxproj
git commit -m "feat(display): IOAVService DDC transport, display registry and control center

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: Key capture in MediaKeyInterceptor + tap lifecycle

**Files:**
- Modify: `Brow/observers/MediaKeyInterceptor.swift`
- Modify: `Brow/BrowViewCoordinator.swift` (observers ~lines 170–225)

**Interfaces:**
- Consumes: `ShortcutMatcher`, `SwallowedKeyTracker`, `DisplayKeyAction` (Task 5); `DisplayControlCenter.shared.router` (Task 7); `Defaults[.externalDisplayControl]` (Task 7)

- [ ] **Step 1: Imports + state** — in `MediaKeyInterceptor.swift` add `import KeyboardShortcuts` to the imports, and next to `private var audioPlayer: AVAudioPlayer?` add:

```swift
    private var swallowedKeys = SwallowedKeyTracker()
```

- [ ] **Step 2: Start guard + event mask** — in `start(promptIfNeeded:)` replace

```swift
        // Ensure HUD replacement is enabled
        guard Defaults[.hudReplacement] else {
```
with
```swift
        // The tap serves both the HUD replacement and external-display keys
        guard Defaults[.hudReplacement] || Defaults[.externalDisplayControl] else {
```

and replace the mask + callback:

```swift
        let mask = CGEventMask(1 << kSystemDefinedEventType.rawValue)
            | CGEventMask(1 << CGEventType.keyDown.rawValue)
            | CGEventMask(1 << CGEventType.keyUp.rawValue)
        eventTap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, cgEvent, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(cgEvent) }
                let interceptor = Unmanaged<MediaKeyInterceptor>.fromOpaque(userInfo).takeUnretainedValue()
                return interceptor.handleEvent(type: type, cgEvent)
            },
            userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())
        )
```

- [ ] **Step 3: Event dispatch** — replace everything from `private func handleEvent(_ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {` through `let command = flags.contains(.command)` with:

```swift
    private func handleEvent(type: CGEventType, _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS disables slow taps; turn it straight back on.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap { CGEvent.tapEnable(tap: eventTap, enable: true) }
            return Unmanaged.passUnretained(cgEvent)
        }
        if type == .keyDown || type == .keyUp {
            return handleKeyEvent(type: type, cgEvent)
        }

        // Ensure the CGEvent has a valid type before converting to NSEvent
        guard cgEvent.type != .null else {
            return Unmanaged.passRetained(cgEvent)
        }
        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passRetained(cgEvent)
        }

        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = ((data1 & 0xFF00) >> 8)

        // 0xA = key down, 0xB = key up. Only handle key down.
        guard stateByte == 0xA,
              let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passRetained(cgEvent)
        }

        let flags = nsEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)

        // External monitor under the cursor / monitor speakers as output → DDC.
        if Defaults[.externalDisplayControl], let action = displayAction(for: keyType, command: command) {
            let claimed = MainActor.assumeIsolated { DisplayControlCenter.shared.router.claimsMediaKey(action) }
            if claimed {
                MainActor.assumeIsolated { DisplayControlCenter.shared.router.perform(action, fine: option && shift) }
                return nil
            }
        }

        // Everything else is the HUD replacement's job; without it, leave the key to macOS.
        guard Defaults[.hudReplacement] else {
            return Unmanaged.passRetained(cgEvent)
        }
```

(The remaining lines — `// Handle option key action (without shift)` onwards — stay unchanged.)

- [ ] **Step 4: New helpers** — add below `handleEvent`:

```swift
    // MARK: - External display keys (any keyboard)

    private func handleKeyEvent(type: CGEventType, _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyUp {
            return swallowedKeys.shouldSwallowUp(keyCode) ? nil : Unmanaged.passUnretained(cgEvent)
        }
        guard Defaults[.externalDisplayControl] else { return Unmanaged.passUnretained(cgEvent) }

        // CGEventFlags and NSEvent.ModifierFlags share bit values.
        let flags = NSEvent.ModifierFlags(rawValue: UInt(cgEvent.flags.rawValue))
        let match = ShortcutMatcher.match(
            keyCode: keyCode,
            flags: flags,
            bindings: ShortcutMatcher.currentBindings(),
            suspended: isRecordingShortcut()
        )
        guard case let .action(action, fine) = match else { return Unmanaged.passUnretained(cgEvent) }

        swallowedKeys.noteSwallowedDown(keyCode)
        MainActor.assumeIsolated { DisplayControlCenter.shared.router.perform(action, fine: fine) }
        return nil
    }

    /// While a KeyboardShortcuts recorder in Brow's Settings has focus, keys
    /// must reach it so the user can record F1 etc.
    private func isRecordingShortcut() -> Bool {
        guard NSApp.isActive, let responder = NSApp.keyWindow?.firstResponder else { return false }
        if responder is KeyboardShortcuts.RecorderCocoa { return true }
        if let editor = responder as? NSTextView, editor.delegate is KeyboardShortcuts.RecorderCocoa { return true }
        return false
    }

    private func displayAction(for keyType: NXKeyType, command: Bool) -> DisplayKeyAction? {
        switch keyType {
        case .brightnessUp: command ? nil : .brightnessUp       // ⌘ = keyboard backlight
        case .brightnessDown: command ? nil : .brightnessDown
        case .soundUp: .volumeUp
        case .soundDown: .volumeDown
        case .mute: .volumeMute
        case .keyboardBrightnessUp, .keyboardBrightnessDown: nil
        }
    }
```

- [ ] **Step 5: Coordinator tap lifecycle** — in `Brow/BrowViewCoordinator.swift`:

Add a property next to `hudReplacementCancellable`:
```swift
    private var externalDisplayControlCancellable: AnyCancellable?
```

In the accessibility observer, replace `if Defaults[.hudReplacement] {` with:
```swift
                if Defaults[.hudReplacement] || Defaults[.externalDisplayControl] {
```

In the `hudReplacementCancellable` sink, replace the `else { MediaKeyInterceptor.shared.stop() }` branch with:
```swift
                    } else if !Defaults[.externalDisplayControl] {
                        MediaKeyInterceptor.shared.stop()
                    }
```

After the `hudReplacementCancellable = …` statement add (`options: []` — no initial emission, so launch never prompts for Accessibility):
```swift
        externalDisplayControlCancellable = Defaults.publisher(.externalDisplayControl, options: [])
            .sink { change in
                Task { @MainActor in
                    if change.newValue {
                        DisplayControlCenter.shared.start()
                        let granted = await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: true)
                        if granted {
                            await MediaKeyInterceptor.shared.start()
                        } else {
                            Defaults[.externalDisplayControl] = false
                        }
                    } else {
                        DisplayControlCenter.shared.stop()
                        if !Defaults[.hudReplacement] {
                            MediaKeyInterceptor.shared.stop()
                        }
                    }
                }
            }
```

Extend the launch block added in Task 7 so the tap also starts when only this feature is on:
```swift
            if Defaults[.externalDisplayControl] {
                DisplayControlCenter.shared.start()
                if await XPCHelperClient.shared.isAccessibilityAuthorized() {
                    await MediaKeyInterceptor.shared.start(promptIfNeeded: false)
                }
            }
```

- [ ] **Step 6: Build + full tests**

Run: `xcodebuild -scheme Brow -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5 && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`.

- [ ] **Step 7: Hardware key check** (Debug app launched as in Task 7 Step 9, Accessibility granted to the Debug build)

With the external keyboard, cursor on DELL S2421H: F2 ×3 → monitor visibly brighter, notch HUD shows brightness. F1 ×3 → dimmer. Move cursor to P2419HC → only that monitor changes. ⌘F1 → keyboard-backlight shortcut behaviour unchanged (no monitor change). In TextEdit, a bare `A` still types.

- [ ] **Step 8: Commit**

```bash
git add Brow/observers/MediaKeyInterceptor.swift Brow/BrowViewCoordinator.swift
git commit -m "feat(display): capture F-keys from any keyboard for external displays

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: Settings UI + license attribution

**Files:**
- Modify: `Brow/components/Settings/SettingsView.swift` (`struct HUD`, ~line 577)
- Modify: `THIRD_PARTY_LICENSES`

**Interfaces:**
- Consumes: `DisplayControlCenter.shared.displays / displayAudioNames` (Task 7), `ExternalDisplay.statusLabel(hasSpeakers:)`, `ExternalDisplay.normalizedName` (Task 6), shortcut names (Task 5)

- [ ] **Step 1: State** — in `struct HUD`, after `@Default(.hudReplacement) var hudReplacement`:

```swift
    @Default(.externalDisplayControl) var externalDisplayControl
    @ObservedObject var displayControl = DisplayControlCenter.shared
```

- [ ] **Step 2: Section** — insert as the second `Section` of the `Form` (right after the "Replace system HUD" section's closing `}` and before the `Section { Picker("Option key behaviour", …` ). It is intentionally **not** `.disabled(!hudReplacement)`:

```swift
            Section {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Control external displays with keyboard")
                            .font(.headline)
                        Text("Change brightness and speaker volume of external monitors over DDC/CI. Works with any keyboard.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 40)
                    Defaults.Toggle("", key: .externalDisplayControl)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.large)
                        .disabled(!accessibilityAuthorized)
                }

                Group {
                    KeyboardShortcuts.Recorder("Brightness down:", name: .displayBrightnessDown)
                    KeyboardShortcuts.Recorder("Brightness up:", name: .displayBrightnessUp)
                    KeyboardShortcuts.Recorder("Mute:", name: .displayVolumeMute)
                    KeyboardShortcuts.Recorder("Volume down:", name: .displayVolumeDown)
                    KeyboardShortcuts.Recorder("Volume up:", name: .displayVolumeUp)
                }
                .disabled(!externalDisplayControl)

                if displayControl.displays.isEmpty {
                    Text("No external displays connected.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(displayControl.displays) { display in
                        HStack {
                            Text(display.name)
                            Spacer()
                            Text(display.statusLabel(
                                hasSpeakers: displayControl.displayAudioNames.contains(ExternalDisplay.normalizedName(display.name))
                            ))
                            .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("External displays")
            } footer: {
                Text("Brightness follows the display under the pointer. Volume keys drive the monitor's speakers when they are the current sound output. Monitors without DDC/CI are dimmed in software.")
            }
```

- [ ] **Step 3: License attribution** — append MonitorControl's MIT license to `THIRD_PARTY_LICENSES`, in the same banner style the file already uses:

```bash
{
  printf '\n-----------------------------------------------------------------------------\n'
  printf '                        MIT License\n'
  printf '        applies to:\n'
  printf '        - Brow/Managers/DisplayControl (DDC framing, IOAVService matching), ported from\n'
  printf '          MonitorControl, https://github.com/MonitorControl/MonitorControl\n'
  printf -- '-----------------------------------------------------------------------------\n\n'
  curl -sL https://raw.githubusercontent.com/MonitorControl/MonitorControl/main/License.txt
} >> THIRD_PARTY_LICENSES
tail -30 THIRD_PARTY_LICENSES
```
Expected: the tail shows the banner followed by `MIT License` / `Copyright © 2017 …` / the permission text.

- [ ] **Step 4: Build + full tests**

Run: `xcodebuild -scheme Brow -configuration Debug -destination 'platform=macOS' build 2>&1 | tail -5 && xcodebuild test -scheme Brow -destination 'platform=macOS' -only-testing:BrowTests 2>&1 | tail -5`
Expected: `** BUILD SUCCEEDED **`, `** TEST SUCCEEDED **`.

- [ ] **Step 5: UI check** — launch Debug app → Settings → HUDs: "External displays" section shows the toggle, 5 recorders prefilled F1/F2/F10/F11/F12, and rows `DELL P2419HC — DDC`, `DELL S2421H — DDC + speakers`. Click the "Brightness down" recorder, press ⌃F1 → it records ⌃F1 (brightness does **not** change while recording). Then bare F1 does nothing to the monitor, ⌃F1 dims. Reset the recorder back to F1 (clear, press F1).

- [ ] **Step 6: Commit**

```bash
git add Brow/components/Settings/SettingsView.swift THIRD_PARTY_LICENSES
git commit -m "feat(display): settings for external display keys, MonitorControl attribution

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: End-to-end verification on target hardware

**Files:**
- Modify: `docs/superpowers/specs/2026-09-30-external-display-keys-design.md` (Status line)

- [ ] **Step 1: Run the spec's manual checklist** (Debug build, external keyboard unless noted). Record pass/fail per line in the task report:

1. F1/F2 on each Dell follows the cursor; holding F2 ramps smoothly and stops where the HUD stops; `⌥⇧F2` moves in small steps.
2. Apple internal keyboard (lid open, or any Apple keyboard) brightness/volume media keys drive the same actions for the external monitors.
3. Sound output = DELL S2421H: F11/F12 change monitor speaker volume, F10 mutes/unmutes back to the previous level. Sound output = ULT WEAR: F11/F12 change system volume as before.
4. Unplug and replug a monitor; sleep and wake the Mac → keys keep working within ~3 s.
5. Dell OSD → Others → DDC/CI **off** on one monitor → after ≤3 presses F1 dims it in software; turning DDC/CI back on + replug restores DDC.
6. Toggle "Control external displays with keyboard" off → any software dimming is restored, F1/F2 reach other apps again (e.g. F1 opens Help in apps that bind it).
7. Rebinding flow from Task 9 Step 5.

- [ ] **Step 2: Update spec status** — change `**Status:** Draft for review (no implementation started)` to `**Status:** Implemented (2026-09-30)`.

- [ ] **Step 3: Commit**

```bash
git add docs/superpowers/specs/2026-09-30-external-display-keys-design.md
git commit -m "docs: mark external display keys spec implemented

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
