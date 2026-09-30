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
    func activeDisplay() -> CGDirectDisplayID?
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
        case .brightnessDown, .brightnessUp: activeDisplay() != nil
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

    private func activeDisplay() -> ExternalDisplay? {
        guard let id = env.activeDisplay() else { return nil }
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
        guard let display = activeDisplay() else {
            env.adjustBuiltinBrightness(delta: Float(delta))
            return
        }
        if display.ddcAvailable, let writer = display.brightnessWriter {
            display.brightness = clamp(display.brightness + delta)
            display.brightnessTouched = true
            writer.submit(Self.ddcValue(BrightnessScale.hardware(atPosition: display.brightness), max: display.brightnessMax))
            let software = BrightnessScale.software(atPosition: display.brightness)
            if software < 1 || display.softwareLevel < 1 {
                display.softwareLevel = software
                env.applyGamma(level: software, to: display.id)
            }
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
