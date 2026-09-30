//
//  AudioOutput.swift
//  Brow
//

import CoreAudio
import Foundation

struct AudioOutputInfo: Equatable {
    let name: String
    /// HDMI or DisplayPort transport — audio carried to a monitor.
    let isDisplayAudio: Bool
}

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
