# External Display Brightness & Volume Keys — Design Spec

**Date:** 2026-09-30
**Status:** Implemented; manual hardware checklist (§7) pending user verification
**Reference project:** [`MonitorControl/MonitorControl`](https://github.com/MonitorControl/MonitorControl) (DDC/CI over `IOAVService` on Apple Silicon, gamma fallback, audio-device ↔ display matching).

---

## 1. Goal

Let the user change the **brightness** and **speaker volume** of external monitors
with keyboard keys — F1/F2 for brightness, F10/F11/F12 for mute/volume — exactly as the
built-in display of a MacBook behaves, **from any keyboard** (not only Apple keyboards),
with Brow's notch HUD as the on-screen feedback.

Target hardware in daily use: MacBook Pro M4 Pro in clamshell, DELL P2419HC + DELL S2421H
(S2421H on HDMI, has built-in speakers), non-Apple external keyboard + occasional Apple
internal keyboard.

### Why it does not work today

| Piece | Today | Gap |
|---|---|---|
| `MediaKeyInterceptor` | CGEventTap on `systemDefined` (NX media keys) only | Non-Apple keyboards send F1/F2 as plain `keyDown` (keyCode 122/120) — never seen |
| `BrightnessManager` → XPC helper | `DisplayServices` / `IODisplay` | Works only on Apple/built-in panels; external monitors need DDC/CI |
| `VolumeManager` | CoreAudio `VolumeScalar` on default output | HDMI/DisplayPort audio devices expose no volume control — macOS locks the volume |

### Locked decisions (from stakeholder)

| Decision | Choice |
|---|---|
| **Key mapping** | Fixed defaults F1/F2 (brightness −/+), F10/F11/F12 (mute/vol−/vol+), **rebindable** in Settings. Physical media keys (NX events) also supported. |
| **Brightness target** | Display currently under the mouse cursor. |
| **Volume target** | Follows the current default audio output: monitor audio (HDMI/DP) → DDC volume on that monitor; anything else → system volume as today. |
| **No-DDC fallback** | Software dimming via gamma table (can only dim, never exceed the monitor's hardware level). No fallback for volume. |
| **Architecture** | DDC in the main app (both app and XPC helper are non-sandboxed, so no reason to add an XPC hop); extend the existing event tap; store bindings with `KeyboardShortcuts.Name`. |

## 2. Non-Goals

- Contrast, input source switching, or other VCP codes (MonitorControl extras).
- Intel Macs (`IOI2C` DDC path). Apple Silicon `IOAVService` only; Intel users get gamma fallback for brightness.
- Syncing external brightness with the built-in ambient light sensor.
- Per-display brightness sliders in the notch UI (HUD feedback only).
- Keyboard backlight changes (`KeyboardBacklightManager` untouched).

## 3. Architecture

```
Brow/Managers/DisplayControl/
  DDC/DDCPacket.swift           — pure: encode VCP get/set, checksum, parse get-reply (current, max)
  DDC/DDCChannel.swift          — DDCTransport protocol + retrying VCP read/write over a transport (MonitorControl timings)
  DDC/Arm64DDCTransport.swift   — IOAVServiceCreateWithService / ReadI2C / WriteI2C via dlsym; conforms to DDCTransport
  ExternalDisplay.swift         — one monitor: CGDirectDisplayID, UUID, name, transport, capability, cached values
  DisplayRegistry.swift         — CGDisplay ↔ IOAVService matching; rebuilds on reconfiguration and wake
  DDC/DDCWriteCoalescer.swift   — latest-value-wins writer on the DDC serial queue, reports each result
  GammaDimmer.swift             — CGSetDisplayTransferByTable fallback; restore on disable/quit
  DisplayControlRouter.swift    — @MainActor entry point: brightness(delta:), volume(delta:), toggleMute()
Brow/observers/MediaKeyInterceptor.swift  — adds keyDown/keyUp handling, shortcut matching, tap re-enable
Brow/Shortcuts/ShortcutConstants.swift    — 5 new KeyboardShortcuts.Name
Brow/models/Constants.swift               — Defaults keys
Brow/components/Settings/SettingsView.swift (HUD section) — toggle, 5 recorders, display list with DDC status
```

### Units and their contracts

| Unit | Does | Depends on |
|---|---|---|
| `DDCPacket` | Builds DDC/CI payloads written to I2C address `0x37`, sub-address `0x51` (framing copied from MonitorControl `Arm64DDC.performDDCCommunication`): set = `[0x84, 0x03, vcp, hi, lo, chk]` with `chk = 0x6E ^ 0x51 ^ (bytes)`; get = `[0x82, 0x01, vcp, chk]` with `chk = 0x6E ^ (bytes)`. Parses the 11-byte get-reply (read from offset 0; `reply[6…7]` = max, `reply[8…9]` = current, `reply[10]` = `0x50 ^ reply[0…9]`) into `(current: UInt16, max: UInt16)` or an error. | nothing (pure) |
| `DDCTransport` (protocol) | `write(_ packet: [UInt8]) -> Bool`, `read(count: Int) -> [UInt8]?` for one display. | — |
| `Arm64DDCTransport` | Real transport. Private symbols (`IOAVServiceCreateWithService`, `IOAVServiceReadI2C`, `IOAVServiceWriteI2C`) resolved with `dlsym` from IOKit; missing symbols → transport unavailable (not a crash). | IOKit |
| `DisplayRegistry` | Enumerates `CGGetOnlineDisplayList`, skips built-in (`CGDisplayIsBuiltin`), matches each to a `DCPAVServiceProxy` IORegistry entry (location `External`, EDID vendor/product/serial ↔ `CGDisplayVendorNumber`/`ModelNumber`/`SerialNumber`, same strategy as MonitorControl `Arm64DDC.getServiceMatches`). Publishes `[ExternalDisplay]`. | IOKit, CoreGraphics |
| `DDCChannel` | `write(vcp:value:)` / `read(vcp:)`: up to 3 attempts, each = 2 write cycles 10 ms apart (+50 ms before reading a reply), 20 ms between attempts. | `DDCTransport` |
| `DDCWriteCoalescer` | Accepts target values; if a write is in flight, replaces the pending value (latest wins). Reports success/failure of each write to the display. | `DDCChannel` |
| `GammaDimmer` | Scales the display's original transfer table by factor `max(0.1, level)`. `restoreAll()` → `CGDisplayRestoreColorSyncSettings`. | `GammaApplying` protocol (CoreGraphics in prod) |
| `DisplayControlRouter` | Decides where a key action goes and fires the HUD. | Registry, `BrightnessManager`, `VolumeManager`, `AudioOutputProviding` |

Existing `BrightnessManager` / `VolumeManager` public API stays unchanged; the Router calls
into them for built-in displays and non-monitor audio.

### Settings / Defaults

| Key | Type | Default |
|---|---|---|
| `externalDisplayControl` | Bool | `true` (effective only once Accessibility is granted) |
| `externalDisplayLevels` | `[String: Double]` keyed `"<displayUUID>.brightness"` / `".volume"` | empty |

`KeyboardShortcuts.Name` additions (bindings persisted by the library, edited via `KeyboardShortcuts.Recorder`):

| Name | Default |
|---|---|
| `displayBrightnessDown` | F1 (no modifiers) |
| `displayBrightnessUp` | F2 |
| `displayVolumeMute` | F10 |
| `displayVolumeDown` | F11 |
| `displayVolumeUp` | F12 |

These names are **not** registered as Carbon hotkeys (`onKeyDown` is never called for them);
they are used only for storage + recorder UI. Matching happens in the event tap. Existing
`decreaseBacklight`/`increaseBacklight` (⌘F1/⌘F2) keep working because matching requires
exact modifiers.

The event tap runs when `hudReplacement || externalDisplayControl`. When only
`externalDisplayControl` is on, NX media keys are still handled for the external-display
cases, but built-in brightness / non-monitor volume NX keys are passed through to macOS
unchanged (no behaviour change for users who never enabled HUD replacement).

## 4. Data Flow

### 4.1 Key capture (`MediaKeyInterceptor`)

- Event mask: `systemDefined | keyDown | keyUp`.
- `keyDown`: normalise modifiers (drop `.function`, `.numericPad`, `.capsLock`, device-dependent bits) and compare `(keyCode, modifiers)` to each bound shortcut.
  - Exact match → action with normal step (1/16).
  - Match with extra `⌥⇧` → action with fine step (1/64), as macOS does.
  - Match → return `nil` (swallow) and remember the keyCode so the matching `keyUp` is swallowed too.
  - No match → return the event unchanged.
- Autorepeat `keyDown` events (holding the key) repeat the action.
- `systemDefined` NX events (brightness up/down, sound up/down, mute) → same Router actions.
- `tapDisabledByTimeout` / `tapDisabledByUserInput` → `CGEvent.tapEnable(tap:, enable: true)`.
- Callback does no I/O: it only dispatches to the Router on the main actor.

### 4.2 Brightness

```
F2 → Router.brightness(delta: +1/16)
   → screen under NSEvent.mouseLocation → CGDirectDisplayID
      built-in           → BrightnessManager.setRelative (unchanged path)
      external, DDC ok   → cache += delta (clamped 0…1) → HUD(.brightness, cache) immediately
                           → coalescer.submit(round(cache * max))
      external, no DDC   → GammaDimmer.set(level) → HUD(.brightness, level)
```

- First use per display: DDC get VCP `0x10` to learn `current` and `max` (usually 100). If the read fails, use the persisted level from `externalDisplayLevels`, else 0.5.
- After a successful write, the level is persisted (debounced 1 s).

### 4.3 Volume

```
F11/F12 → Router.volume(delta: ∓/±1/16)
   → default output device (CoreAudio)
      transport type HDMI or DisplayPort AND device name matches an ExternalDisplay name
            → that display's DDC VCP 0x62 (independent of mouse position) → HUD(.volume)
      otherwise → VolumeManager.increase/decrease (unchanged path)
F10 → monitor: remember level, write 0 / restore remembered level; HUD(.volume, 0 or level)
      (VCP 0x8D mute is poorly supported, so it is not used)
```

Name matching: case-insensitive, trimmed; CoreAudio device name for HDMI audio is the
EDID product name (e.g. `DELL S2421H`), the same string as `NSScreen.localizedName`.

## 5. Error Handling & Lifecycle

| Situation | Behaviour |
|---|---|
| DDC write fails 3 attempts | Count failure; after 3 consecutive failed writes the display is marked `noDDC`: brightness switches to gamma, volume falls back to CoreAudio. Logged via `Logger`. |
| DDC read fails on first use | Use persisted/default level (4.2); do not mark `noDDC` from a read alone. |
| Display connected/disconnected | `CGDisplayRegisterReconfigurationCallback` → rebuild registry, cancel pending writes for removed displays, re-apply gamma levels. |
| Wake from sleep | `NSWorkspace.didWakeNotification` → rebuild registry (IOAVService handles go stale). `noDDC` flags reset. |
| Feature disabled / app quits | `GammaDimmer.restoreAll()`; stop tap if `hudReplacement` also off. |
| Accessibility not granted | Enabling the toggle prompts via existing `XPCHelperClient.ensureAccessibilityAuthorization`; denied → toggle reverts, same as `hudReplacement`. |
| Secure Input active (password fields) | macOS blocks the tap; keys do nothing then. Documented limitation. |
| Other gamma-altering apps (f.lux etc.) | May conflict with gamma fallback. Documented limitation. |

## 6. Settings UI

In the existing HUD section of `SettingsView`:

- Toggle **"Control external displays with keyboard"**.
- Five `KeyboardShortcuts.Recorder` rows (Brightness down/up, Mute, Volume down/up).
- Read-only list of connected external displays with status: `DDC`, `Software dimming`, or `DDC + speakers` (speakers = a matching HDMI/DP audio device exists).

## 7. Testing

### Unit tests (XCTest, `BrowTests/`)

Hardware seams behind protocols: `DDCTransport`, `GammaApplying`, `AudioOutputProviding`, plus a
`DisplayProviding` that supplies the screen under the cursor.

| Test file | Covers |
|---|---|
| `DDCPacketTests` | set/get encoding, checksum, reply parsing (valid, bad checksum, short, garbage) |
| `ShortcutMatchTests` | keyCode + modifier normalisation, `.function` flag ignored, `⌥⇧` fine step, ⌘F1 not matched by bare-F1 binding, unbound key passes through |
| `DisplayControlRouterTests` | built-in → BrightnessManager; external DDC → transport; 3 failures → gamma; volume HDMI name match → DDC; Bluetooth/built-in output → VolumeManager; mute remember/restore; clamping at 0/1 |
| `DDCWriteCoalescerTests` | 10 rapid submits → last value written; retries; failure counting |
| `GammaDimmerTests` | table scaling, 10 % floor, restore |

### Manual verification (on target hardware)

1. External keyboard: F1/F2 on each Dell, following the cursor; hold for repeat; `⌥⇧` fine step; HUD appears.
2. Apple internal keyboard media keys drive the same actions.
3. F10–F12 with output = DELL S2421H (DDC volume) vs Bluetooth headset (system volume).
4. Unplug/replug a monitor; sleep/wake; keys keep working.
5. Disable DDC in the Dell OSD → brightness falls back to gamma dimming.
6. Disable the feature → gamma restored, F1/F2 reach other apps again.
7. Rebind brightness to ⌃F1 in Settings → bare F1 passes through, ⌃F1 works.
