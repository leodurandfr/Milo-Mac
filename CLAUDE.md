# Milo Mac

macOS menu-bar companion app for **Milō** — a Raspberry Pi audio appliance. The Pi runs the Python backend at https://github.com/leodurandfr/Milo; this repo is a thin Swift/AppKit remote that talks to it over HTTP + WebSocket and (optionally) streams Mac audio to it via `roc-vad`.

## The backend is the source of truth

Whenever you add or change a feature that touches audio sources, feature toggles, settings, or the wire protocol, the canonical definition lives in the `leodurandfr/Milo` repo — not here. Check it first.

- **Audio source IDs**: `AudioSource` enum at `backend/core/models/audio_state.py` (`none`, `spotify`, `bluetooth`, `radio`, `podcast`, `airplay`, `mac`, `cd`). The Swift side uses bare strings — they must match the enum values byte-for-byte.
- **Source operational states**: `SourceState` enum in the same file (`starting`, `waiting`, `active`, `error`). `MiloState.sourceState` stores the raw string; compare lowercased.
- **Enabled apps / ordering**: the backend owns `enabled_apps` (served via `GET /api/settings/dock-apps` → `config.enabled_apps`). This list is both the **filter** (which sources show up) and the **order** (how they're laid out in the menu). The Mac app must not hardcode order — see `MenuItemFactory.createAudioSourcesSection` for the pattern.
- **API contracts**: endpoints like `/api/audio/source/{id}`, `/api/audio/state`, `/api/volume/state`, `/api/volume/adjust`, `/api/equalizer/enabled`, `/api/settings/volume-limits`, `/api/settings/volume-steps`, `/api/radio/*`, `/api/health`. If a payload shape looks wrong, check the backend before "fixing" the parser here.

Quick lookups from this repo:
```
gh search code --repo leodurandfr/Milo "class AudioSource"
gh api repos/leodurandfr/Milo/contents/backend/core/models/audio_state.py
```

## Non-obvious things about this app

- **Product vs. project name**: the Xcode target's `PRODUCT_NAME` is `Milo` (bundle id `leodurand.Milo-Mac`), but the repo/folder is `Milo Mac` and the app is branded **Milō** (macron). The string `Milō` appears in user-facing text; don't strip the macron. One scheme: `Milo Mac.xcscheme`.
- **`milo.local` discovery**: `MiloConnectionManager` uses a state machine (`ConnectionPhase`: idle → discovering → testingAPI → connecting → connected) driven by mDNS (`NetServiceBrowser` on `_http._tcp`), then 20 rapid API health checks, then the WebSocket. When multiple IPv4s resolve, it picks the lowest-latency one via a TCP probe. If you add connection logic, plug into the phase machine — don't bypass it.
- **Two transports, complementary**: HTTP (`MiloAPIService`) for commands and initial state; WebSocket (`WebSocketService`, port 8000, path `/ws`) for push updates. **WebSocket volume events do not carry `limits` or `steps`** — `MenuBarController.didReceiveVolumeUpdate` preserves them from the last `getVolumeStatus()`. Don't regress that: re-introducing 0-valued limits bricks the slider.
- **Localization**: always use `L("key")` (see `LocalizationHelper.swift`) — never `NSLocalizedString` directly. Any new string must be added to **all** `*.lproj/Localizable.strings` files (`en`, `fr`, `de`, `es`, `it`, `pt-PT`, `hi`, `zh-Hans`). English and French are authoritative and kept in lockstep (identical line count).
- **Custom menu items**: sources/features use `CircularMenuItem` with custom `NSView`s so clicks don't auto-dismiss the menu (letting us show loading spinners and update in place). If you add a menu row, follow that pattern instead of a vanilla `NSMenuItem`.
- **Loading state is orchestrated, not reactive**: `MenuBarController` has `loadingStates`, `manualLoadingProtection` (2 s floor to avoid flicker), and `minimumFunctionalityLoadingDuration` (1.2 s). Source transitions are auto-resolved by observing `sourceState == "starting"` / `transitioning` on incoming state; feature toggles (`multiroom`, `equalizer`) are resolved by matching the new state against `expectedFunctionalityStates`. Don't add ad-hoc `isLoading` flags.
- **Mac-as-source requires `roc-vad`**: `RocVADManager` installs/checks the virtual audio driver at `/usr/local/bin/roc-vad`. The Mac source is useless without it. Driver config (`configureDeviceOnly`) must run on `deviceQueue` (serial) — concurrent `roc-vad` calls race.
- **Source assets live in the asset catalog**: source icons are either SF Symbols (`music.note`, `bluetooth`, `radio`, `desktopcomputer`) or custom image sets in `Assets.xcassets` (`podcasts-icon`, `menubar-icon`, etc.). Adding a new source means adding an asset **and** wiring it into `allSourceConfigs` in `MenuItemFactory`.

## Adding a new audio source — checklist

1. Confirm the `AudioSource` enum value exists (or add it) in the backend repo first.
2. Add a tuple to `MenuItemFactory.allSourceConfigs` — `(title: L("source.X"), iconName, sourceId)`. The `sourceId` must equal the backend enum value.
3. Add `"source.X"` to every `*.lproj/Localizable.strings`.
4. Add the icon to `Assets.xcassets` if not an SF Symbol.
5. Whether it shows up at runtime is gated by the backend's `enabled_apps` — confirm the source is listed there.
6. If the source needs a submenu (like Radio favorites), extend `MenuBarController.addAudioSourcesSection`: build the submenu, attach it via `item.submenu = submenu` so NSMenu handles the flyout natively on hover, and add a decorative chevron (`NSImageView` with `chevron.right`) to the item's custom view.

## SourceKit / IDE indexing

SourceKit-LSP can't parse Xcode's `.pbxproj` directly, so cross-file symbol resolution (the `Cannot find X in scope` false positives you sometimes see while editing) depends on a `buildServer.json` at the repo root generated by [`xcode-build-server`](https://github.com/SolaWing/xcode-build-server).

- Install: `brew install xcode-build-server`
- Regenerate: `xcode-build-server config -project "Milo Mac.xcodeproj" -scheme "Milo Mac"` (run from the repo root)
- `buildServer.json` is gitignored — it holds machine-specific absolute paths (DerivedData, workspace). Each contributor generates their own.
- Rerun the `config` command after: adding/renaming a target, renaming the scheme, or major project-file restructuring. Adding a Swift file to an existing target does **not** require regeneration.
- The underlying index store lives in Xcode's DerivedData — a successful `xcodebuild ... build` is what populates it, so if diagnostics look stale, rebuild first.

## Testing

Unit/UI test targets exist (`Milo MacTests`, `Milo MacUITests`) but are effectively placeholder. There is no CI in this repo. Manual smoke test after any menu/state change:

1. Build & run; confirm menu-bar icon appears.
2. With Milō reachable on the LAN, menu should populate within a few seconds.
3. Click a source, toggle multiroom/equalizer, move the volume slider — verify loading spinners and state sync.
4. Option-click the menu-bar icon to open the preferences menu.
