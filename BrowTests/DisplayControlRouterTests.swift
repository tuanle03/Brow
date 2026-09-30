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
        XCTAssertEqual(brightnessWriter.values, [50]) // position 0.5625 → hardware (0.5625-0.125)/0.875 = 0.5
        XCTAssertEqual(env.huds.last?.type, .brightness)
        XCTAssertEqual(env.huds.last?.value ?? -1, 0.5625, accuracy: 1e-9)
        XCTAssertEqual(env.persisted["UUID-2.brightness"] ?? -1, 0.5625, accuracy: 1e-9)
    }

    func testFineStep() {
        router.perform(.brightnessUp, fine: true)
        XCTAssertEqual(brightnessWriter.values, [45]) // position 0.515625 → hardware 0.446
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

    // MARK: Brightness below the monitor's hardware minimum (hardware + software dimming)

    func testBrightnessScaleMapping() {
        XCTAssertEqual(BrightnessScale.hardware(atPosition: 0.125), 0, accuracy: 1e-9)
        XCTAssertEqual(BrightnessScale.hardware(atPosition: 1), 1, accuracy: 1e-9)
        XCTAssertEqual(BrightnessScale.hardware(atPosition: 0), 0, accuracy: 1e-9)
        XCTAssertEqual(BrightnessScale.software(atPosition: 0.125), 1, accuracy: 1e-9)
        XCTAssertEqual(BrightnessScale.software(atPosition: 0.0625), 0.6, accuracy: 1e-9)
        XCTAssertEqual(BrightnessScale.software(atPosition: 0), BrightnessScale.softwareFloor, accuracy: 1e-9)
        XCTAssertEqual(BrightnessScale.position(hardware: 0.5), 0.5625, accuracy: 1e-9)
    }

    func testBrightnessBelowHardwareZeroUsesGamma() {
        display.brightness = 0.125 // hardware already at 0
        router.perform(.brightnessDown, fine: false)
        XCTAssertEqual(display.brightness, 0.0625, accuracy: 1e-9)
        XCTAssertEqual(brightnessWriter.values.last, 0)
        XCTAssertEqual(env.gamma.last?.id, 2)
        XCTAssertEqual(env.gamma.last?.level ?? -1, 0.6, accuracy: 1e-9)
        XCTAssertEqual(env.huds.last?.value ?? -1, 0.0625, accuracy: 1e-9)
    }

    func testBrightnessZeroReachesSoftwareFloor() {
        display.brightness = 0.0625
        router.perform(.brightnessDown, fine: false)
        XCTAssertEqual(display.brightness, 0, accuracy: 1e-9)
        XCTAssertEqual(env.gamma.last?.level ?? -1, BrightnessScale.softwareFloor, accuracy: 1e-9)
    }

    func testBrightnessUpLeavingSoftwareZoneRestoresGamma() {
        display.brightness = 0.0625
        display.softwareLevel = 0.6 // gamma was applied when we entered the zone
        router.perform(.brightnessUp, fine: false)
        XCTAssertEqual(display.brightness, 0.125, accuracy: 1e-9)
        XCTAssertEqual(env.gamma.last?.level ?? -1, 1, accuracy: 1e-9)
    }

    func testNormalBrightnessDoesNotTouchGamma() {
        router.perform(.brightnessUp, fine: false)
        XCTAssertTrue(env.gamma.isEmpty)
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

    func testInitialBrightnessReadingMapsIntoScale() {
        display.applyInitialReadings(brightness: DDCReading(current: 50, max: 100), volume: nil)
        XCTAssertEqual(display.brightness, 0.5625, accuracy: 1e-9)
    }

    func testStatusLabel() {
        XCTAssertEqual(display.statusLabel(hasSpeakers: true), "DDC + speakers")
        XCTAssertEqual(display.statusLabel(hasSpeakers: false), "DDC")
        for _ in 0..<ExternalDisplay.failureThreshold { display.recordWriteResult(false) }
        XCTAssertEqual(display.statusLabel(hasSpeakers: true), "Software dimming")
    }
}
