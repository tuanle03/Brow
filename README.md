# Brow

Brow is a personal macOS notch-overlay app built on top of
[**boring.notch**](https://github.com/TheBoredTeam/boring.notch) by The
Boring Team. The fork starts from feature parity with upstream and
grows from there.

> Brow is licensed under the **GNU General Public License v3.0** — the
> same license as upstream. Every commit in this repository inherits
> GPL v3.

## Status

Early. The upstream import has just landed; bundle identifiers,
signing, and CI have been rebranded but the user-facing surface still
reads largely as boring.notch. Brow-specific UI, icon, and feature
work happens on follow-up branches.

## Requirements

- macOS **14 Sonoma** or later
- Xcode **16** or later (Swift toolchain bundled with it)
- Apple Silicon or Intel Mac

## Build from source

```bash
git clone git@github.com:tuanle03/Brow.git
cd Brow
open Brow.xcodeproj
```

In Xcode, select the **Brow** scheme and Run (`⌘R`). The first build
resolves Swift Package dependencies, which can take a moment.

Signing is configured for development team `3AGYM77Y39`; if you build
the fork yourself, set your own team in the project's *Signing &
Capabilities* tab.

## Project layout

```
Brow/                  application target (Swift / SwiftUI)
BrowXPCHelper/         XPC helper for accessibility + brightness APIs
mediaremote-adapter/   bundled MediaRemoteAdapter for macOS 15.4+
Configuration/         signing, DMG, Sparkle config
.github/workflows/     CI (Build for macOS on push / PR)
```

## Attribution

Upstream copyright (c) The Boring Team contributors. See
[`NOTICE.md`](./NOTICE.md) for the GPL v3 modification notice and
[`UPSTREAM_README.md`](./UPSTREAM_README.md) for the original upstream
README, preserved verbatim.

Third-party library credits live in
[`THIRD_PARTY_LICENSES`](./THIRD_PARTY_LICENSES).
