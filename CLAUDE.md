# Milo Mac

macOS menu-bar companion app for **Milō** — a Raspberry Pi audio appliance. The Pi runs the Python backend at https://github.com/leodurandfr/Milo; this repo is a thin Swift/SwiftUI remote that talks to it over HTTP + WebSocket and (optionally) streams Mac audio to it via `roc-vad`.

The app is a **native macOS 26 panel**: an `NSStatusItem` that opens an `NSPanel` filled with Liquid Glass, hosting a SwiftUI view. It is not an `NSMenu`, and the reasons why are load-bearing — see *The panel*, below.

## The backend is the source of truth

Whenever you add or change a feature that touches audio sources, feature toggles, settings, or the wire protocol, the canonical definition lives in the `leodurandfr/Milo` repo — not here. Check it first.

- **Audio source IDs**: `AudioSource` enum at `backend/core/models/audio_state.py` (`none`, `spotify`, `bluetooth`, `radio`, `podcast`, `airplay`, `mac`, `cd`). The Swift side uses bare strings — they must match the enum values byte-for-byte.
- **Source operational states**: `SourceState` enum in the same file (`starting`, `waiting`, `active`, `error`). `MiloState.sourceState` stores the raw string; compare lowercased.
- **Enabled apps / ordering**: the backend owns `enabled_apps` (served via `GET /api/settings/bulk` → `dock_apps.enabled_apps`, cached on connect; pushed live via WebSocket `settings/dock_apps_changed`). This list is both the **filter** (which sources show up) and the **order** (how they're laid out). The Mac app must not hardcode order — `AudioSourceCatalog.ordered(enabledApps:)` is the only place that decides what's displayed.
- **API contracts**: endpoints like `/api/audio/state`, `/api/audio/source/{id}`, `/api/routing/multiroom`, `/api/volume/state`, `/api/volume/adjust`, `/api/equalizer/target/local/enabled`, `/api/settings/bulk`, `/api/radio/*`. If a payload shape looks wrong, check the backend before "fixing" the parser here.

Quick lookups from this repo:
```
gh search code --repo leodurandfr/Milo "class AudioSource"
gh api repos/leodurandfr/Milo/contents/backend/core/models/audio_state.py
```

## Building

**`xcode-select` points at the CommandLineTools, which cannot build this project.** Every `xcodebuild` invocation must override it:

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "Milo Mac.xcodeproj" -scheme "Milo Mac" \
  -configuration Debug -destination 'platform=macOS' build
```

`MACOSX_DEPLOYMENT_TARGET = 26.0`: the app runs **only on macOS 26+**. That is not a preference — `NSGlassEffectView` (the panel's background) is macOS 26 API, and there is no fallback path. Don't add `@available` guards hoping to lower the target; the panel has no non-glass rendering.

The project builds at **`SWIFT_VERSION = 6.0`** with **zero warnings**, in Debug and Release. Keep it that way — see *Concurrency*.

## Concurrency: the main-thread invariant is compiler-enforced

Almost everything in this app is main-thread-only, and that is now stated in the type system rather than in comments. **`@MainActor`**: `MiloStore`, `MenuBarShell`, the SwiftUI views, `VolumeController`, `GlobalHotkeyManager`, `VolumeHUD`, `MiloConnectionManager`, `WebSocketService`, `RocVADManager`, `SettingsViewModel`, `SettingsWindowPresenter`. Both delegate protocols (`MiloConnectionManagerDelegate`, `WebSocketServiceDelegate`) are `@MainActor` too, so a callback cannot silently arrive off-main.

The three things that are deliberately **not** main-isolated — each for a real reason:

- **`MiloAPIService` is `Sendable`, not `@MainActor`.** It is called from the Swift-concurrency pool (all its methods are `async`) and from a utility DNS-resolution queue. Its mutable state lives in a `Mutex` (`import Synchronization`) and every other stored property is a `let`, so the `Sendable` conformance is **checked** — no `@unchecked`.
- **`RocVADDevice` is an `actor` whose executor is a serial `DispatchQueue`.** Concurrent `roc-vad` invocations corrupt each other (each one lists, deletes, recreates and configures the "Milō" device), so serialization is correctness, not tidiness. The actor uses `DispatchSerialQueue` as its `SerialExecutor`, which preserves the old serial-queue behaviour exactly *and* keeps the blocking `Process.waitUntilExit()` calls off Swift's cooperative pool. **No method on that actor may contain an `await`** — a suspension point would reintroduce the interleaving the serial queue exists to prevent. That is why progress is reported by fire-and-forget `Task { @MainActor in … }` rather than awaited.
- **`WebSocketService`'s receive loop and `URLSessionWebSocketDelegate` methods are `nonisolated`.** URLSession delivers them on its own delegate queue. They decode off-main into a `Sendable` `DecodedEvent`, then hop to main to deliver — which also keeps the "ignore unhandled broadcasts without a main-thread hop" optimisation intact. The connection **generation** counter is the only state crossing that boundary (it exists to discard callbacks from a stale socket after a sleep/wake reconnect) — hence a `Mutex`.

`MiloState` is `Sendable`, which matters because it is decoded off-main and handed to the main actor. Its `metadata` is `[String: any Sendable]`, built by `JSONSendable.dictionary(_:)`. **Do not "simplify" that to `json["metadata"] as? [String: any Sendable]`** — `Sendable` is a marker protocol with no runtime representation, so that cast *always succeeds without checking anything*. It would be an `@unchecked` in disguise. The explicit rebuild keeps `NSNumber` values as-is, so existing `as? Int` / `as? String` reads behave identically.

### `MainActor.assumeIsolated`

Several callbacks arrive on the main thread but through APIs whose types can't say so: a CGEvent tap (a C function pointer), `NetService`/`NetServiceBrowser` delegates, `Timer` blocks, `NSEvent` monitors, `DispatchQueue.main.async`. Those use `MainActor.assumeIsolated`, which asserts at runtime what the run loop already guarantees. It is **not** a way to silence the compiler:

- The CGEvent tap's run-loop source is installed on `CFRunLoopGetCurrent()` **from the main thread** (`GlobalHotkeyManager.setupEventTap`), so the tap fires on main. The pre-refactor code already depended on this — it drove `VolumeHUD` (AppKit) straight from the tap callback.
- Bonjour delivers on the run loop the browser was scheduled on, which is main.

`assumeIsolated` **traps** if the assumption is ever wrong, so a bad one surfaces immediately at runtime instead of corrupting state. Prefer it to `Task { @MainActor in … }` wherever the callback must stay synchronous — a return value the caller reads (the `NSEvent` monitor decides whether to swallow a click), or a tight loop where a run-loop hop would add jitter (`VolumeHUD`'s 120 Hz animation). Note it only carries `Sendable` values out, which is why several of these closures return a `Bool` and do the non-Sendable work outside.

## Architecture

### `MiloStore` — the UI's source of truth

An `@Observable` class holding connection state, `MiloState`, volume, `enabledApps`, radio favourites, and the loading/spinner state. SwiftUI views observe it directly and re-render themselves; there is no view-rebuilding controller. It is also the `MiloConnectionManagerDelegate`, so every backend push lands here.

### The panel — `MenuBarShell`

An `NSStatusItem` that opens a borderless `NSPanel`, whose content view is an `NSGlassEffectView` (macOS 26 Liquid Glass) wrapping the SwiftUI `MiloPanelView`. The file's comments explain the dead ends in detail; the short version:

- **Not `NSMenu`**: it paints its own chrome and no public API changes it. Measured 14.5 pt corners and a hard border, against 18 pt and a soft edge on the system modules (Sound, Bluetooth). Impossible to match from inside a menu.
- **Not `MenuBarExtra`**: it takes over the `NSStatusItem`, so you lose control of the icon (the dimmed-when-disconnected state) and of option-click. Its `.menu` style ignores images and can't host a slider.
- **Not `NSPopover`**: it always draws an arrow at its anchor, and that can't be hidden.
- **Not the SwiftUI `.glassEffect()` modifier**: inside a transparent `NSPanel` it renders the whole window invisible, content included. The AppKit view is required.

The price of a window is that click-outside-to-dismiss must be re-implemented by hand (a global `NSEvent` monitor), and the panel must be able to become key — otherwise the glass renders in its "inactive", visibly lighter state.

### The panel's measurements are measured

`MenuRowMetrics` and `PanelMetrics` (in `MiloMenuRows.swift`) are **pixel measurements taken from the system's own "Sound" and "Bluetooth" panels**, at 2×, ink-to-ink: a 32 pt row pitch, an 18 pt corner radius, the panel's left edge 11.5 pt left of the icon's ink, a 60.5 pt transparent shadow margin, and so on. Each constant carries a comment saying what was measured and how.

**Do not adjust these by eye.** They look arbitrary and are not; several were wrong once and were fixed by re-measuring (the row pitch sat at 3.25 on the strength of a comment, until measuring centre-to-centre gave 3). If one looks off, screenshot the system panel and measure it — or leave it alone.

Two are subtle and easy to break:

- `shadowMargin` (60.5 pt) only lands on a whole pixel if the content height is an integer, which is why `positionPanel` rounds it up. Without that the panel drifted a pixel depending on the parity of its content.
- `PanelWindow.constrainFrameRect` is overridden to return the rect unchanged. AppKit otherwise shoves any window whose top edge crosses the menu bar back down — and our window is *deliberately* taller than the panel, to give the shadow room to spread. Remove the override and the panel opens 60 pt too low.

### Loading state is orchestrated, not reactive

Lives in `MiloStore`, ported unchanged from the old controller.

- `loadingStates` — spinners, keyed by source id or feature id.
- `manualLoadingProtection` — a **grace window** (`manualLoadingGraceDuration`, 2 s), *not* a minimum display time. It only bridges the click→`transition_start` race, so a stale pre-transition broadcast can't clear a spinner before the backend takes over. The entry is dropped the moment a `transitioning`/`starting` state for that source arrives; after that the spinner clears as soon as the backend reports the transition done, matching the web frontend's timing.
- `minimumFunctionalityLoadingDuration` (1.2 s) — a genuine display floor, but only for feature toggles, so a toggle answering in 80 ms doesn't flash.
- A source click shows its spinner immediately, so the clear path has to be airtight: `syncLoadingStatesWithBackend` schedules a deferred re-check at the end of the grace window (`scheduleGraceWindowSourceLoadingClear`), so a fast transition that settles in `WAITING` with no further broadcast still clears instead of hanging until the 15 s safety timer.
- Source transitions resolve by observing `sourceState == "starting"` / `transitioning`; feature toggles resolve by matching incoming state against `expectedFunctionalityStates`. Multiroom is the exception: the backend pre-sets `multiroom_enabled` *before* doing the real routing work, so intermediate states already carry the new value — it is resolved by the `multiroom_changed` discriminator on the WebSocket, not by comparing state.

Don't add ad-hoc `isLoading` flags.

## Connection

- **`milo.local` discovery**: `MiloConnectionManager` runs a phase machine (`ConnectionPhase`: idle → discovering → testingAPI → connecting → connected) driven by mDNS (`NetServiceBrowser` on `_http._tcp`), then up to 20 rapid API readiness checks (`fetchState()` → `/api/audio/state`; there is no dedicated health route), then the WebSocket. When several IPv4s resolve, it picks the lowest-latency one with a TCP probe. New connection logic must plug into the phase machine, not bypass it.
- **Two transports, complementary**: HTTP (`MiloAPIService`) for commands and initial state; WebSocket (`WebSocketService`, port 8000, path `/ws`) for push updates.
- **⚠️ `volume/volume_changed` events don't carry limits** — the backend sends 0/0. `MiloStore.didReceiveVolumeUpdate` substitutes the cached limits. Don't regress that: storing 0/0 gives the slider an empty range and bricks it.
- **Settings come from `/api/settings/bulk`, cached**: fetched once per connection (`MiloAPIService.fetchBulkSettings`) and cached, so the volume HUD never re-pulls the bulk payload. They update live via WebSocket `settings/volume_limits_changed` and `settings/dock_apps_changed`, mirroring the Milō frontend's settingsStore. The old per-category routes (`/api/settings/{volume-limits,volume-steps,dock-apps}`) are gone — don't reintroduce them.
- The keyboard-shortcut volume step is **local** (`GlobalHotkeyManager.volumeDeltaDb`, 1–6 dB, in Settings), *not* the backend's `step_mobile_db`. `VolumeStatus` has no step field.

## roc-vad is a state, not a toll

`RocVADManager` handles the virtual audio driver at `/usr/local/bin/roc-vad`. The **Mac** source needs it; nothing else does. So the app never blocks on it at launch, never demands installation, and never refuses to start: the menu-bar icon appears immediately, the Mac source simply shows as unavailable, and Settings offers to install it. The driver only loads after a reboot, which the app reports (`rocVADNeedsRestart`) rather than forcing.

See *Concurrency* for the serialization rule on `RocVADDevice` — it is the one place where getting concurrency wrong silently corrupts a real device.

## Localization

Always use `L("key")` (`LocalizationHelper.swift`) — never `NSLocalizedString` directly. Any new string must be added to **all 8** `*.lproj/Localizable.strings` (`en`, `fr`, `de`, `es`, `it`, `pt-PT`, `hi`, `zh-Hans`). English and French are authoritative and kept in lockstep (identical line count — currently 92).

The product is branded **Milō**, with the macron. The Xcode target's `PRODUCT_NAME` is `Milo` (so the Swift module is `Milo`, which is what the tests `@testable import`), the bundle is `Milō.app`, the bundle id is `leodurand.Milo-Mac`, and the repo folder is `Milo Mac`. One scheme: `Milo Mac`. Don't strip the macron from user-facing text.

## Adding a new audio source

1. Confirm the `AudioSource` enum value exists (or add it) in the backend repo first. The id string must match byte-for-byte.
2. Add an `AudioSourceDescriptor` to `AudioSourceCatalog.all` — `.init(id:titleKey:icon:)`. `icon` is either `.symbol("sf.symbol.name")` or `.asset("name-in-catalog")`; the two size differently on purpose (assets carry their own padding and fill the whole circle, SF Symbols size by font), so don't force them into one frame.
3. Add the `titleKey` to all 8 `*.lproj/Localizable.strings`.
4. Add the icon to `Assets.xcassets` if it isn't an SF Symbol.
5. Whether it appears at runtime is gated by the backend's `enabled_apps` — confirm the source is listed there. The order in `AudioSourceCatalog.all` is a **fallback only**; the real order comes from the backend.

`FeatureCatalog` works the same way for toggles (multiroom, equalizer). Its defaults differ, though: multiroom shows unless disabled (`?? true`), the equalizer only shows if explicitly listed (`?? false`).

A source needing a sub-view (like Radio's station list) is *not* a submenu — the panel has no native flyouts. `MiloPanelView` swaps its `route` in place (`Route.root` / `.radioStations`), and the row shows a chevron.

## SourceKit / IDE indexing

SourceKit-LSP can't parse Xcode's `.pbxproj` directly, so cross-file symbol resolution (the `Cannot find X in scope` false positives you sometimes see while editing) depends on a `buildServer.json` at the repo root generated by [`xcode-build-server`](https://github.com/SolaWing/xcode-build-server).

- Install: `brew install xcode-build-server`
- Regenerate: `xcode-build-server config -project "Milo Mac.xcodeproj" -scheme "Milo Mac"` (from the repo root)
- `buildServer.json` is gitignored — it holds machine-specific absolute paths. Each contributor generates their own.
- Rerun the `config` command after: adding/renaming a target, renaming the scheme, or major project-file restructuring. Adding a Swift file to an existing target does **not** require it.
- The index store lives in Xcode's DerivedData — a successful `xcodebuild … build` is what populates it. If diagnostics look stale, build first.

## Testing

`Milo MacTests` is real and worth keeping green. `BulkSettingsBootstrapTests` drives an actual `MiloStore` against `StubMiloBackend` — a **real local HTTP server** on an ephemeral port, not a mocked `URLSession` — so the tests exercise the genuine network stack, parsing and retry paths. It covers the `/api/settings/bulk` bootstrap: retried on failure at connect, recovered when the panel is opened, and retried by the background poll. One test really does wait out the 30 s background-refresh interval.

```
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project "Milo Mac.xcodeproj" -scheme "Milo Mac" \
  -destination 'platform=macOS' test
```

There is no CI. After any change to the panel, state handling, or concurrency, also smoke-test by hand — these are the paths no test covers:

1. Build & run; the menu-bar icon appears immediately (even with Milō unreachable, and even without roc-vad).
2. With Milō on the LAN, the panel populates within a few seconds.
3. Click a source, toggle multiroom/equalizer, drag the volume slider — check the spinners resolve and the state syncs.
4. Open the Radio station list, play a station, come back.
5. Option-click the menu-bar icon — the footer (Settings, Quit) appears.
6. Right-Option + ↑/↓ — the volume HUD appears and tracks. **This is the one path that exercises the CGEvent tap**, and it needs Accessibility permission granted to the built binary.
