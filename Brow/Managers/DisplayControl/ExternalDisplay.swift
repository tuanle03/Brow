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
            if !brightnessTouched { brightness = BrightnessScale.position(hardware: Double(b.current) / Double(b.max)) }
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

/// One brightness axis for a DDC monitor: position 1 → hardware max, down to
/// `softwareZone` → hardware minimum (VCP 0x10 = 0, which on many panels is
/// still readable), then gamma dimming takes over down to `softwareFloor`.
enum BrightnessScale {
    static let softwareZone = 0.125
    static let softwareFloor = 0.2

    static func hardware(atPosition p: Double) -> Double {
        max(0, (p - softwareZone) / (1 - softwareZone))
    }

    static func software(atPosition p: Double) -> Double {
        p >= softwareZone ? 1 : softwareFloor + (1 - softwareFloor) * (max(0, p) / softwareZone)
    }

    static func position(hardware h: Double) -> Double {
        softwareZone + h * (1 - softwareZone)
    }
}
