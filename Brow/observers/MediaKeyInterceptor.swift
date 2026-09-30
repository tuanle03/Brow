//
//  MediaKeyInterceptor.swift
//  Brow
//
//  Created by Alexander on 2025-11-23.

import Foundation
import AppKit
import ApplicationServices
import Defaults
import AVFoundation
import KeyboardShortcuts

private let kSystemDefinedEventType = CGEventType(rawValue: 14)!

final class MediaKeyInterceptor {
    static let shared = MediaKeyInterceptor()
    
    private enum NXKeyType: Int {
        case soundUp = 0
        case soundDown = 1
        case brightnessUp = 2
        case brightnessDown = 3
        case mute = 7
        case keyboardBrightnessUp = 21
        case keyboardBrightnessDown = 22
    }
    
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private let step: Float = 1.0 / 16.0
    private var audioPlayer: AVAudioPlayer?
    private var swallowedKeys = SwallowedKeyTracker()
    
    private init() {}
    
    // MARK: - Accessibility (via XPC)
    
    func requestAccessibilityAuthorization() {
        XPCHelperClient.shared.requestAccessibilityAuthorization()
    }
    
    func ensureAccessibilityAuthorization(promptIfNeeded: Bool = false) async -> Bool {
        await XPCHelperClient.shared.ensureAccessibilityAuthorization(promptIfNeeded: promptIfNeeded)
    }
    
    // MARK: - Event Tap
    
    @MainActor func start(promptIfNeeded: Bool = false) async {
        guard eventTap == nil else { return }
        
        // The tap serves both the HUD replacement and external-display keys
        guard Defaults[.hudReplacement] || Defaults[.externalDisplayControl] else {
            stop()
            return
        }
        
        // Check accessibility authorization
        let authorized = await XPCHelperClient.shared.isAccessibilityAuthorized()
        fputs("[MediaKeyInterceptor] start: accessibility authorized=\(authorized) prompt=\(promptIfNeeded)\n", stderr)
        if !authorized {
            if promptIfNeeded {
                let granted = await ensureAccessibilityAuthorization(promptIfNeeded: true)
                guard granted else { return }
            } else {
                return
            }
        }
        
        // The awaits above suspend; a concurrent start() may have installed the tap meanwhile.
        guard eventTap == nil else { return }

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
        
        fputs("[MediaKeyInterceptor] tap created=\(eventTap != nil)\n", stderr)
        if let eventTap {
            runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
            if let runLoopSource {
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
            }
            CGEvent.tapEnable(tap: eventTap, enable: true)
        }
    }
    
    func stop() {
        if let eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
        }
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        runLoopSource = nil
        eventTap = nil
    }
    
    // MARK: - Event Handling
    
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
            return Unmanaged.passUnretained(cgEvent)
        }
        guard let nsEvent = NSEvent(cgEvent: cgEvent),
              nsEvent.type == .systemDefined,
              nsEvent.subtype.rawValue == 8 else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let data1 = nsEvent.data1
        let keyCode = (data1 & 0xFFFF_0000) >> 16
        let stateByte = ((data1 & 0xFF00) >> 8)
        
        // 0xA = key down, 0xB = key up. Only handle key down.
        guard stateByte == 0xA,
              let keyType = NXKeyType(rawValue: keyCode) else {
            return Unmanaged.passUnretained(cgEvent)
        }
        
        let flags = nsEvent.modifierFlags
        let option = flags.contains(.option)
        let shift = flags.contains(.shift)
        let command = flags.contains(.command)

        // External monitor under the cursor / monitor speakers as output → DDC.
        if Defaults[.externalDisplayControl], let action = displayAction(for: keyType, command: command) {
            let router = MainActor.assumeIsolated { DisplayControlCenter.shared.router }
            if MainActor.assumeIsolated({ router.claimsMediaKey(action) }) {
                let fine = option && shift
                DispatchQueue.main.async { MainActor.assumeIsolated { router.perform(action, fine: fine) } }
                return nil
            }
        }

        // Everything else is the HUD replacement's job; without it, leave the key to macOS.
        guard Defaults[.hudReplacement] else {
            return Unmanaged.passUnretained(cgEvent)
        }

        // Handle option key action (without shift)
        if option && !shift {
            if handleOptionAction(for: keyType, command: command) {
                return nil
            }
        }
        
        // Handle normal key press
        handleKeyPress(keyType: keyType, option: option, shift: shift, command: command)
        return nil
    }
    
    // MARK: - External display keys (any keyboard)

    private func handleKeyEvent(type: CGEventType, _ cgEvent: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = Int(cgEvent.getIntegerValueField(.keyboardEventKeycode))
        if type == .keyDown, [120, 122, 109, 103, 111].contains(keyCode) {
            fputs("[MediaKeyInterceptor] keyDown code=\(keyCode) flags=\(cgEvent.flags.rawValue) feature=\(Defaults[.externalDisplayControl])\n", stderr)
        }
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
            suspended: false
        )
        // Cheap match first; the responder-chain lookup only runs for bound keys.
        guard case let .action(action, fine) = match, !isRecordingShortcut() else {
            return Unmanaged.passUnretained(cgEvent)
        }

        swallowedKeys.noteSwallowedDown(keyCode)
        // Keep the tap callback fast: macOS disables taps that block for ~1 s.
        DispatchQueue.main.async {
            MainActor.assumeIsolated { DisplayControlCenter.shared.router.perform(action, fine: fine) }
        }
        return nil
    }

    /// While a KeyboardShortcuts recorder in Brow's Settings has focus, keys
    /// must reach it so the user can record F1 etc.
    private func isRecordingShortcut() -> Bool {
        MainActor.assumeIsolated {
            guard NSApp.isActive, let responder = NSApp.keyWindow?.firstResponder else { return false }
            if responder is KeyboardShortcuts.RecorderCocoa { return true }
            if let editor = responder as? NSTextView, editor.delegate is KeyboardShortcuts.RecorderCocoa { return true }
            return false
        }
    }

    private func displayAction(for keyType: NXKeyType, command: Bool) -> DisplayKeyAction? {
        switch keyType {
        case .brightnessUp: return command ? nil : .brightnessUp       // ⌘ = keyboard backlight
        case .brightnessDown: return command ? nil : .brightnessDown
        case .soundUp: return .volumeUp
        case .soundDown: return .volumeDown
        case .mute: return .volumeMute
        case .keyboardBrightnessUp, .keyboardBrightnessDown: return nil
        }
    }

    private func handleOptionAction(for keyType: NXKeyType, command: Bool) -> Bool {
        let action = Defaults[.optionKeyAction]
        
        switch action {
        case .openSettings:
            openSystemSettings(for: keyType, command: command)
            return true
        case .showHUD:
            showHUD(for: keyType, command: command)
            return true
        case .none:
            return true
        }
    }
    
    private func prepareAudioPlayerIfNeeded() {
        guard audioPlayer == nil else { return }

        let defaultPath = "/System/Library/LoginPlugins/BezelServices.loginPlugin/Contents/Resources/volume.aiff"
        if FileManager.default.fileExists(atPath: defaultPath) {
            do {
                audioPlayer = try AVAudioPlayer(contentsOf: URL(fileURLWithPath: defaultPath))
                print("🔊 [MediaKeyInterceptor] Loaded default Bezel audio from: \(defaultPath)")
            } catch {
                print("⚠️ [MediaKeyInterceptor] Failed to init AVAudioPlayer with default path \(defaultPath): \(error.localizedDescription)")
            }
        } else {
            print("⚠️ [MediaKeyInterceptor] Default bezel audio not found at: \(defaultPath)")
        }

        if let player = audioPlayer {
            player.volume = 1.0
            player.numberOfLoops = 0
            player.prepareToPlay()
        }
    }

    private func playFeedbackSound() {
        guard let feedback = UserDefaults.standard.persistentDomain(forName: "NSGlobalDomain")?["com.apple.sound.beep.feedback"] as? Int,
              feedback == 1 else { return }

        prepareAudioPlayerIfNeeded()
        guard let player = audioPlayer else {
            print("⚠️ [MediaKeyInterceptor] No audio player available to play feedback sound")
            return
        }
        if let url = player.url {
            print("🔊 [MediaKeyInterceptor] Playing feedback sound from: \(url.path)")
        } else {
            print("🔊 [MediaKeyInterceptor] Playing feedback sound (no url available for AVAudioPlayer)")
        }
        if player.isPlaying {
            player.stop()
            player.currentTime = 0
        }
        player.play()
    }

    private func handleKeyPress(keyType: NXKeyType, option: Bool, shift: Bool, command: Bool) {
        let stepDivisor: Float = (option && shift) ? 4.0 : 1.0
        
        switch keyType {
        case .soundUp:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.increase(stepDivisor: stepDivisor)
            }
        case .soundDown:
            Task { @MainActor in
                self.playFeedbackSound()
                VolumeManager.shared.decrease(stepDivisor: stepDivisor)
            }
        case .mute:
            Task { @MainActor in
                VolumeManager.shared.toggleMuteAction()
            }
        case .brightnessUp, .keyboardBrightnessUp:
            let delta = step / stepDivisor
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessUp || command)
        case .brightnessDown, .keyboardBrightnessDown:
            let delta = -(step / stepDivisor)
            adjustBrightness(delta: delta, keyboard: keyType == .keyboardBrightnessDown || command)
        }
    }
    
    private func adjustBrightness(delta: Float, keyboard: Bool) {
        Task { @MainActor in
            if keyboard {
                KeyboardBacklightManager.shared.setRelative(delta: delta)
            } else {
                BrightnessManager.shared.setRelative(delta: delta)
            }
        }
    }
    
    private func showHUD(for keyType: NXKeyType, command: Bool) {
        Task { @MainActor in
            switch keyType {
            case .soundUp, .soundDown, .mute:
                let v = VolumeManager.shared.rawVolume
                BrowViewCoordinator.shared.toggleSneakPeek(status: true, type: .volume, value: CGFloat(v))
            case .brightnessUp, .brightnessDown:
                if command {
                    let v = KeyboardBacklightManager.shared.rawBrightness
                    BrowViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
                } else {
                    let v = BrightnessManager.shared.rawBrightness
                    BrowViewCoordinator.shared.toggleSneakPeek(status: true, type: .brightness, value: CGFloat(v))
                }
            case .keyboardBrightnessUp, .keyboardBrightnessDown:
                let v = KeyboardBacklightManager.shared.rawBrightness
                BrowViewCoordinator.shared.toggleSneakPeek(status: true, type: .backlight, value: CGFloat(v))
            }
        }
    }
    
    private func openSystemSettings(for keyType: NXKeyType, command: Bool) {
        let urlString: String
        
        switch keyType {
        case .soundUp, .soundDown, .mute:
            urlString = "x-apple.systempreferences:com.apple.preference.sound"
        case .brightnessUp, .brightnessDown:
            if command {
                urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
            } else {
                urlString = "x-apple.systempreferences:com.apple.preference.displays"
            }
        case .keyboardBrightnessUp, .keyboardBrightnessDown:
            urlString = "x-apple.systempreferences:com.apple.preference.keyboard"
        }
        
        guard let url = URL(string: urlString) else { return }
        NSWorkspace.shared.open(url)
    }
}
