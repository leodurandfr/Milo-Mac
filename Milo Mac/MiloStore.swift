import Foundation
import Observation

/// What the panel can display. The panel has no native submenus: the radio station list
/// is not a flyout, it replaces the root content in place.
enum PanelRoute: Hashable, Sendable {
    case root
    case radioStations
    case musicLibrarySearch
    case musicLibraryArtist
    case musicLibraryAlbum

    /// The routes of the "music library" thread: moving within it keeps the search and the pages,
    /// leaving it clears them (see `MiloStore.finishRouteMorph`). An exhaustive `switch` rather than
    /// a literal `Set` — a route added later cannot forget to place itself.
    var isMusicLibrary: Bool {
        switch self {
        case .musicLibrarySearch, .musicLibraryArtist, .musicLibraryAlbum: true
        case .root, .radioStations: false
        }
    }
}

/// A song displayed by `NowPlayingRow`, whatever the source — see `MiloStore.nowPlaying`.
struct NowPlayingInfo: Equatable {
    /// The song's Subsonic identifier (`details.track_id`), for now only for the
    /// music library (`nil` everywhere else, radio included) — used to tell whether ONE
    /// specific search-result/album row is the current one (see
    /// `MiloStore.isCurrentMusicLibrarySong`).
    let id: String?
    let title: String
    let artist: String?
    let artworkURL: URL?
    /// A badge displayed in a corner of the cover art — for now, only the STATION's logo
    /// when Radio is playing a recognized song with its own cover art (see
    /// `MiloStore.nowPlayingInfo`). `nil` everywhere else.
    let badgeArtworkURL: URL?
    /// `session.phase == playing` — loading, paused, connected and a mere resume point are not.
    let isPlaying: Bool
}

/// The UI's source of truth: the SwiftUI views observe these properties and re-render
/// themselves. Nothing rebuilds a menu on every event.
///
/// The loading state machine (the spinners) is the subtle part of this class —
/// see the comments alongside `syncLoadingStatesWithBackend`.
///
/// This class is used **exclusively from the main thread**, and `@MainActor` has the
/// compiler check that instead of entrusting it to this comment: MiloConnectionManager
/// and WebSocketService already deliver all their delegate calls on the main actor, and the
/// Timers/asyncAfter calls here run there too. The `Task`s created here inherit it — hence
/// the absence of `MainActor.run`: after a network `await`, we are already back on main.
@MainActor
@Observable
final class MiloStore {

    // MARK: - State observed by the views

    private(set) var isConnected = false
    private(set) var state: MiloAudioState?
    private(set) var volume: VolumeStatus?
    private(set) var enabledApps: [String]?
    private(set) var radioFavorites: [RadioStation]?

    /// The term typed in the music library's search field. Empty at rest —
    /// this is the value (not yet debounced) that the `TextField` displays.
    private(set) var musicLibrarySearchTerm = ""
    private(set) var musicLibrarySearchResults: MusicLibrarySearchResults = .empty
    /// True for the span of a network round trip — NOT for the debounce, which sets nothing
    /// (see `updateMusicLibrarySearchTerm`).
    private(set) var musicLibrarySearchLoading = false
    /// True from the first non-empty search sent — tells "not searched yet"
    /// (the prompt row) from "searched, zero results" (the "no results" row).
    private(set) var musicLibrarySearchHasSearched = false
    /// The song whose playback is in flight: its row shows a spinner.
    private(set) var musicLibrarySongLoadingId: String?
    /// The artist whose header button started the current queue. The backend does NOT publish
    /// what the queue is — only the current song — so nothing allows rediscovering
    /// after the fact that "we are listening to this artist". This is display memory, not system
    /// state: it clears as soon as another playback takes over (a song, an
    /// album) or an artist page is reopened, where the button therefore goes back to play.
    ///
    /// The album needs no such crutch: its song list is displayed, so
    /// `isCurrentMusicLibraryAlbum` can INFER it from the current song, and it survives a
    /// round trip away from the page.
    private(set) var musicLibraryPlayingArtistId: String?

    /// The album or artist whose QUEUE is being assembled by the header's play button:
    /// its icon gives way to a spinner. Distinct from
    /// `musicLibrarySongLoadingId` — starting an artist requires one album fetch per release and
    /// can take a while, where a song goes off in a single request, and the two spinners do not
    /// target the same row.
    private(set) var musicLibraryContextLoadingId: String?
    private var musicLibrarySearchTask: Task<Void, Never>?

    /// The artist whose page (albums) we are visiting — `nil` outside that route. Set by
    /// `showMusicLibraryArtist(_:)`, which also loads `musicLibraryArtistAlbums`.
    private(set) var musicLibraryViewedArtist: MusicLibraryArtist?
    private(set) var musicLibraryArtistAlbums: [MusicLibraryAlbum] = []
    private(set) var musicLibraryArtistAlbumsLoading = false

    /// The album whose page (songs) we are visiting — `nil` outside that route. Set by
    /// `showMusicLibraryAlbum(_:)`, which also loads `musicLibraryAlbumSongs`. It is THESE
    /// songs (and not the search's) that `play_context` receives as the queue when
    /// playback is started from this page — see `playMusicLibrarySong(_:from:)`.
    private(set) var musicLibraryViewedAlbum: MusicLibraryAlbum?
    private(set) var musicLibraryAlbumSongs: [MusicLibrarySong] = []
    private(set) var musicLibraryAlbumSongsLoading = false

    /// What the search sub-level displays while the field is empty: the recently played
    /// albums — failing that, the recently added ones (see `loadMusicLibraryShowcase()`), which
    /// is what `musicLibraryShowcaseIsRecentlyAdded` says.
    private(set) var musicLibraryShowcaseAlbums: [MusicLibraryAlbum] = []
    private(set) var musicLibraryShowcaseLoading = false
    private(set) var musicLibraryShowcaseIsRecentlyAdded = false
    private var musicLibraryShowcaseTask: Task<Void, Never>?

    /// The showcase's size. The panel is capped to the screen's height and the list scrolls,
    /// so this number bounds the transfer, not the display.
    private static let musicLibraryShowcaseSize = 20

    /// The last detected song, whatever the source — feeds `NowPlayingAccordion`, NOT
    /// `nowPlaying` directly: unlike the latter, it stays populated for a moment after
    /// playback stops, long enough for `MenuBarShell` to animate the row's collapse to zero
    /// (`nowPlayingRevealFraction`). Without it, the row would lose its content BEFORE it had
    /// finished closing. See `syncDisplayedNowPlaying`.
    private(set) var displayedNowPlaying: NowPlayingInfo?

    /// The multiroom structure (zones + clients), read when multiroom is enabled. Empty otherwise.
    /// Feeds the expandable sub-section of the Multiroom row.
    private(set) var multiroom: MultiroomSnapshot = .empty

    /// LIVE volume/mute per client and per zone (zone averages included). Bootstrapped with
    /// the structure, then pushed by `volume/volume_changed`. Feeds the sub-section's sliders
    /// and mute buttons.
    private(set) var multiroomVolume: MultiroomVolume = .empty

    /// The spinners in progress, indexed by source id ("spotify"…) or by
    /// feature id ("multiroom", "equalizer").
    private(set) var loadingStates: [String: Bool] = [:]

    /// The radio station whose playback is in flight: its row shows a spinner.
    private(set) var radioStationLoadingId: String?

    /// The value displayed by the slider. Written by the user (drag) and by
    /// the server echo — but never by the server while the user is
    /// manipulating the slider (cf. `volumeController.isUserInteracting`).
    var sliderVolumeDb: Double = VolumeDefaults.limitMinDb

    /// True as long as the panel is open. Used only to avoid showing the
    /// volume HUD over the panel, and to pause the background poll.
    var isPanelOpen = false

    /// True when the panel was opened with the Option key held: the footer
    /// (Settings, Quit) only appears then. Set by MenuBarShell on opening.
    var showsPreferences = false

    /// True when the multiroom sub-section is expanded under the Multiroom row.
    ///
    /// In the store, and not in the view's local `@State`, for two reasons: `MenuBarShell`
    /// observes it to resize the window (the panel grows/shrinks with the accordion,
    /// like the "Sound" panel under AirPods); and it has to close when the panel closes
    /// or when multiroom is switched off.
    var multiroomExpanded = false

    /// The multiroom accordion's opening fraction, from 0 (collapsed) to 1 (expanded). Animated by a
    /// timer in `MenuBarShell` (and NOT by `withAnimation`): the sub-section has a height of
    /// `natural × fraction`, so that at every step the SwiftUI content has a CONCRETE size,
    /// on which `MenuBarShell` resets the window — where `withAnimation` would report the
    /// final size in one go to `NSHostingController`, making the window jump.
    var multiroomRevealFraction: CGFloat = 0

    /// The collapse/expand fraction of the "now playing" row, from 0 (hidden) to 1 (full
    /// height) — the same mechanism as `multiroomRevealFraction`, for the same reason: animated
    /// step by step by a timer in `MenuBarShell`, never by `withAnimation`.
    ///
    /// Synchronized to the REAL state without animation when the panel opens (`MenuBarShell.
    /// showPanel`) — the user has just opened it, there is nothing to slide. Only the
    /// changes occurring WHILE the panel is open are animated.
    var nowPlayingRevealFraction: CGFloat = 0

    // MARK: - Panel navigation

    /// The panel's current view. A panel has no native submenus: the radio station
    /// list replaces the root content in place.
    ///
    /// In the store, and not in the view's local `@State`, for the same reason as
    /// `multiroomExpanded`: `MenuBarShell` has to observe it to animate the window's height.
    private(set) var panelRoute: PanelRoute = .root

    /// The routes already left, the nearest one last — lets `navigateBack()` go up
    /// exactly one level (album → artist → search), rather than always falling back to the
    /// root as a plain `navigate(to: .root)` would. Radio has only one sub-level,
    /// so it never needed this; the music library stacks up to three.
    private(set) var panelRouteStack: [PanelRoute] = []

    /// The route fading out during the transition; nil at rest. Serves as a discriminator: it is
    /// its update (and not `panelRoute`'s) that triggers the morph in
    /// `MenuBarShell`, so that a return to the root when the panel closes — which goes through
    /// `resetPanelRoute()` — animates nothing.
    private(set) var outgoingPanelRoute: PanelRoute?

    /// The progress of the morph from one route to the other: 0 on click, 1 when the new view is in
    /// place. Already EASED (the timer applies the curve), hence directly interpolable.
    ///
    /// The same idiom as `multiroomRevealFraction`, and for the same reason: the panel's height
    /// changes, and only a timer gives the SwiftUI content a concrete size at every step.
    var routeMorphFraction: CGFloat = 1

    /// True during the transition between two routes.
    var isRouteMorphing: Bool { outgoingPanelRoute != nil }

    /// Navigates to a route, arming the morph, and pushes the route being left so that
    /// `navigateBack()` can return to it precisely. The animation itself is driven by
    /// `MenuBarShell`, which observes `outgoingPanelRoute`.
    func navigate(to route: PanelRoute) {
        guard route != panelRoute else { return }
        panelRouteStack.append(panelRoute)
        outgoingPanelRoute = panelRoute
        routeMorphFraction = 0
        panelRoute = route

        // Entering the search loads its showcase. This is the ONLY trigger: coming back from
        // an artist/album page goes through `navigateBack()`, which finds the one already loaded —
        // reloading it would flash a spinner on a step backwards.
        if route == .musicLibrarySearch { loadMusicLibraryShowcase() }
    }

    /// Returns to the exact parent route (pops), and not systematically to the root — this is
    /// what each music library sub-level's back row calls.
    func navigateBack() {
        let previous = panelRouteStack.popLast() ?? .root
        guard previous != panelRoute else { return }
        outgoingPanelRoute = panelRoute
        routeMorphFraction = 0
        panelRoute = previous
    }

    /// A return to the root emptying the WHOLE stack, animated — unlike `navigateBack()`, which
    /// only goes up one level. Used when the capability that justified the whole current
    /// navigation thread disappears (the active source changes while browsing artist →
    /// album in the music library): there is then no valid parent left to return to, so we
    /// jump straight to the root.
    func exitToRoot() {
        panelRouteStack = []
        guard panelRoute != .root else { return }
        outgoingPanelRoute = panelRoute
        routeMorphFraction = 0
        panelRoute = .root
    }

    /// An immediate return to the root, with no transition — when the panel closes, when there is
    /// nothing left to animate and we definitely do not want to reopen on a half-played animation.
    func resetPanelRoute() {
        panelRoute = .root
        panelRouteStack = []
        outgoingPanelRoute = nil
        routeMorphFraction = 1
    }

    /// End of the morph: the target route is alone in place.
    func finishRouteMorph() {
        outgoingPanelRoute = nil
        routeMorphFraction = 1

        // The music library thread is only cleared HERE, at the very end of the transition, and
        // never on click: the layer being left stays displayed for the whole morph, so
        // clearing it on click showed the search resetting itself mid-fade — the
        // term disappeared and the "Search your library" prompt came back before the
        // user's eyes, by way of a farewell.
        //
        // A deliberate side effect: retracing your steps during the transition (clicking the
        // source again before it ends) finds the search intact, since the destination route is
        // once again one of the thread's.
        if !panelRoute.isMusicLibrary { clearMusicLibraryBrowsing() }
    }

    // MARK: - Dependencies

    let connectionManager = MiloConnectionManager()
    let volumeController = VolumeController()
    private(set) var hotkeyManager: GlobalHotkeyManager?

    // MARK: - roc-vad

    /// The virtual audio driver is only required by the "Mac" source. The app works
    /// without it: it is exposed as a **state** (the source shows up disabled, Settings
    /// offers to install it), never as a condition for starting.
    @ObservationIgnored private(set) var rocVADManager: RocVADManager?

    /// True when the binary is installed **and** the driver answers.
    private(set) var isRocVADReady = false

    /// True between the end of an installation and the restart that will activate it.
    private(set) var rocVADNeedsRestart = false

    private(set) var isInstallingRocVAD = false

    func attachRocVAD(_ manager: RocVADManager) {
        rocVADManager = manager
        connectionManager.rocVADManager = manager
    }

    /// Checks the driver and configures the device, in the background. Shows no alert
    /// and blocks nothing: if roc-vad is missing, we merely reflect that in the UI.
    func prepareRocVADIfInstalled() {
        guard let rocVADManager, RocVADManager.isBinaryInstalled else {
            isRocVADReady = false
            return
        }

        Task {
            // `roc-vad info` queries the driver through gRPC and can take several
            // seconds — hence the await, which does not tie up the main thread.
            let driverLoaded = await rocVADManager.checkInstallation()
            isRocVADReady = driverLoaded

            guard driverLoaded else {
                NSLog("⚠️ roc-vad installed but driver not loaded — restart pending")
                rocVADNeedsRestart = true
                return
            }

            let success = await rocVADManager.configureDeviceOnly()
            NSLog(success ? "✅ roc-vad device configured" : "⚠️ roc-vad device configuration failed")
        }
    }

    /// Installs roc-vad on demand, from Settings.
    func installRocVAD(completion: @escaping @MainActor (Bool) -> Void) {
        guard let rocVADManager, !isInstallingRocVAD else { return }
        isInstallingRocVAD = true

        Task {
            let success = await rocVADManager.performInstallation()
            isInstallingRocVAD = false
            // The driver is only loaded after a restart: we do not claim to be
            // ready, we announce what is left to do.
            rocVADNeedsRestart = success
            completion(success)
        }
    }

    // MARK: - Volume limits

    var volumeLimits: (minDb: Double, maxDb: Double) {
        guard let volume else {
            return (VolumeDefaults.limitMinDb, VolumeDefaults.limitMaxDb)
        }
        return (volume.limitMinDb, volume.limitMaxDb)
    }

    // MARK: - Loading (not observed: internal plumbing)

    @ObservationIgnored private var loadingTimers: [String: Timer] = [:]
    @ObservationIgnored private var loadingStartTimes: [String: Date] = [:]
    @ObservationIgnored private var manualLoadingProtection: [String: Date] = [:]
    @ObservationIgnored private var radioStationLoadingTimer: Timer?

    /// The toggle state a feature is heading to while its spinner runs — see
    /// `displayedToggleState`. OBSERVED, unlike the plumbing above: it is display state.
    /// `canShowMultiroom` derives from it, and the view that reads that (the panel, which
    /// passes the Multiroom row its chevron) reads nothing else that changes on the click —
    /// ignored, the chevron would only appear once the spinner ended.
    private var expectedFunctionalityStates: [String: Bool] = [:]


    // MARK: - Background poll (not observed)

    @ObservationIgnored private var backgroundRefreshTimer: Timer?
    @ObservationIgnored private var consecutiveRefreshFailures = 0
    @ObservationIgnored private var refreshPausedUntil: Date?

    // MARK: - Constants

    private let loadingTimeoutDuration: TimeInterval = 15.0
    private let functionalityLoadingTimeout: TimeInterval = 10.0
    // Multiroom takes longer on the backend side (snapserver startup,
    // wait_for_ready up to 15 s, volume push) — a higher safety timeout.
    private let multiroomLoadingTimeout: TimeInterval = 35.0
    private let minimumFunctionalityLoadingDuration: TimeInterval = 1.2
    // The grace window after a source click: the time it takes the backend to take
    // charge of the transition (`switching` goes true). While it runs and the backend
    // has not confirmed yet, a "non-transitional" state is interpreted as
    // the old state (the click↔switching race) and the spinner is kept. Once
    // the transition is taken in charge, we no longer wait out this delay: the spinner clears
    // as soon as the transition ends (like the web frontend).
    private let manualLoadingGraceDuration: TimeInterval = 2.0
    private let radioStationLoadingTimeout: TimeInterval = 15.0
    private let maxConsecutiveFailures = 3
    // The WebSocket pushes every state change in real time: this poll is
    // only a slow safety net to catch a missed event.
    private let backgroundRefreshInterval: TimeInterval = 30.0
    private let refreshPauseDuration: TimeInterval = 60.0

    // MARK: - Lifecycle

    init() {
        connectionManager.delegate = self
        hotkeyManager = GlobalHotkeyManager(connectionManager: connectionManager, store: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeChangedViaHotkey),
            name: .volumeChangedViaHotkey,
            object: nil
        )
    }

    func start() {
        connectionManager.start()
    }

    // MARK: - Actions

    func selectSource(_ sourceId: String) {
        guard let apiService = connectionManager.apiService, isConnected else { return }

        let activeSource = state?.source ?? "none"
        guard activeSource != sourceId else { return }

        // Avoid concurrent actions while a request is in flight.
        guard loadingStates[sourceId] != true else { return }

        // Start the loading BEFORE the request: an immediate spinner, and a guard against
        // double-clicks during the ~3 s the POST can take.
        startLoading(for: sourceId, timeout: loadingTimeoutDuration)

        Task {
            do {
                try await apiService.changeSource(sourceId)
            } catch {
                // HTTP failure or in-band {"status": "error"}: there is no transition
                // to wait for, so we stop the spinner right away.
                NSLog("❌ Source change to %@ failed: %@", sourceId, error.localizedDescription)
                stopLoading(for: sourceId)
            }
        }
    }

    /// Closes the active source — the backend goes back to `source = "none"`.
    /// Triggered by a press-and-hold on the row, like the hold on the web
    /// frontend's dock.
    func closeSource(_ sourceId: String) {
        guard let apiService = connectionManager.apiService, isConnected else { return }

        // The state may have changed during the press: only close if the target source
        // is still the active one, and no request is in flight.
        guard state?.source == sourceId, loadingStates[sourceId] != true else { return }

        // No startLoading here, unlike selectSource: closing has no
        // startup phase on the backend side (just plugin.stop()), and above all
        // syncLoadingStatesWithBackend would not know how to resolve that spinner — its
        // "transition confirmed" branch tests `identifier == source`, and source
        // becomes "none". The spinner would therefore hold for the whole grace window (2 s) on a row
        // already switched off. The state broadcast is enough. Same choice as the web frontend (onCloseActive).
        Task {
            do {
                try await apiService.changeSource("none")
            } catch {
                NSLog("❌ Closing source %@ failed: %@", sourceId, error.localizedDescription)
            }
        }
    }

    func toggleFeature(_ toggleId: String) {
        guard let apiService = connectionManager.apiService, isConnected else { return }
        guard loadingStates[toggleId] != true else { return }

        let newState = !currentToggleState(toggleId)
        startFunctionalityLoading(for: toggleId, expectedState: newState)

        Task {
            do {
                switch toggleId {
                case "multiroom":
                    try await apiService.setMultiroom(newState)
                case "equalizer":
                    try await apiService.setEqualizer(newState)
                default:
                    stopFunctionalityLoading(for: toggleId)
                    return
                }
            } catch {
                // Multiroom: the PUT can fail even with the extended timeout while
                // the backend finishes the transition. We keep the spinner — it will be
                // resolved by the first state where `switching` is false again (see
                // checkFunctionalityStateChange), by multiroom_error over WebSocket, or
                // by the safety timeout. For the other toggles, we stop right away.
                if toggleId != "multiroom" {
                    stopFunctionalityLoading(for: toggleId)
                } else {
                    NSLog("⚠️ setMultiroom HTTP error (spinner kept until WS signal): %@", error.localizedDescription)
                }
            }
        }
    }

    func currentToggleState(_ toggleId: String) -> Bool {
        switch toggleId {
        case "multiroom": return state?.multiroomEnabled ?? false
        case "equalizer": return state?.equalizerEffectsEnabled ?? true
        default: return false
        }
    }

    /// The state to display for a toggle: during a transition we show the
    /// **expected** state, not the backend's, otherwise the switch would flip
    /// back for the duration of the request.
    func displayedToggleState(_ toggleId: String) -> Bool {
        expectedFunctionalityStates[toggleId] ?? currentToggleState(toggleId)
    }

    // MARK: - Volume

    /// Called by the slider while the user is manipulating it.
    func setVolume(_ db: Double) {
        sliderVolumeDb = db
        volumeController.handleVolumeChange(db)
    }

    func updateVolumeStatus(_ volumeStatus: VolumeStatus) {
        volume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)
        applyServerVolume(volumeStatus.volumeDb)
    }

    /// Applies a value coming from the SERVER to the slider. The single point of passage for every
    /// server path: the WebSocket echo, the background poll, and the `GET /api/volume/state` that the
    /// shortcut triggers at the start of a sequence (`refreshVolumeLimitsInBackground`).
    ///
    /// The slider has two possible drivers, and the second must never be allowed to overwrite the
    /// first: a LOCAL value (immediate, exact) and the SERVER echo of that same value
    /// (which arrives one network round trip later). Hence the three guards below — one
    /// per local driver, plus the drain window that follows.
    ///
    /// - `isUserInteracting`: the user is dragging the slider with the mouse.
    /// - `isActivelyAdjusting`: the keyboard shortcut is holding its local prediction. Without this
    ///   guard, the sequence's opening `GET` returns the volume from BEFORE the delta (its `adjust`
    ///   has not landed yet) and used to drag the thumb backwards.
    /// - `isHotkeySettling`: see below.
    private func applyServerVolume(_ db: Double) {
        guard !volumeController.isUserInteracting else { return }
        guard hotkeyManager?.isActivelyAdjusting != true, !isHotkeySettling else { return }
        setSliderVolume(db)
    }

    /// The window during which server echoes stay ignored AFTER the shortcut's last
    /// notch.
    ///
    /// `isActivelyAdjusting` falls back to false as soon as the key is released — at the worst
    /// possible moment. A hold ticks every 30 ms, far faster than the round trip to the
    /// Pi, and the `adjust` calls are serialized: on release, the echoes of the previous notches
    /// are therefore still in flight. With the guard opening at exactly that moment, they all landed,
    /// dragged the thumb onto a stale value, and the last echo then caught it up —
    /// the little jump on release.
    ///
    /// So we hand control back to the server not on release, but once its echoes have drained.
    /// This is exactly the counter (and the duration) that `VolumeController` already applies to
    /// the mouse drag, where the echoes lag by the same amount: `userInteractionTimeout`.
    /// Not observed: internal plumbing, and rewritten on every notch (30 Hz) — exposing it to the
    /// observation graph would spin the views for nothing.
    @ObservationIgnored private var hotkeySettleUntil: Date?
    private let hotkeySettleDuration: TimeInterval = 0.3

    private var isHotkeySettling: Bool {
        guard let hotkeySettleUntil else { return false }
        return Date() < hotkeySettleUntil
    }

    /// A dead zone: below 0.1 dB, rewriting would only trigger a render for nothing.
    private func setSliderVolume(_ db: Double) {
        guard abs(sliderVolumeDb - db) > 0.1 else { return }
        sliderVolumeDb = db
    }

    @objc private func handleVolumeChangedViaHotkey(_ notification: Notification) {
        guard let volumeStatus = notification.object as? VolumeStatus else { return }

        volume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)

        // Every notch pushes the window back: it therefore runs 0.3 s after the LAST one, whether
        // there was a hold or a single press.
        hotkeySettleUntil = Date().addingTimeInterval(hotkeySettleDuration)

        // The shortcut's LOCAL prediction, and not a server echo: it short-circuits
        // `applyServerVolume`, whose guards it is precisely what arms.
        setSliderVolume(volumeStatus.volumeDb)
    }

    // MARK: - Radio

    func playRadioStation(_ stationId: String) {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 playRadioStation: %@", stationId)

        beginRadioStationLoading(stationId: stationId)
        // Read the state on the main thread (where it is owned) rather than in the
        // Task: the relevant value is the one the user saw at click time.
        let needsSourceSwitch = state?.source != "radio"

        Task {
            do {
                try await apiService.playRadioStation(stationId)
                if needsSourceSwitch {
                    try await apiService.changeSource("radio")
                }
            } catch {
                NSLog("❌ Error playing radio: %@", error.localizedDescription)
                endRadioStationLoading()
            }
        }
    }

    /// Stops playback, without saying which: `/api/radio/stop` takes no station —
    /// the backend only plays one at a time.
    func stopRadioPlayback() {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 stopRadioPlayback")

        Task {
            do {
                try await apiService.stopRadioPlayback()
            } catch {
                NSLog("❌ Error stopping radio: %@", error.localizedDescription)
            }
        }
    }

    /// The absolute URL of a station's logo, or nil if it has none (the caller
    /// then shows a fallback). Delegates to `MiloAPIService`, which knows the
    /// resolved host/port and the favicon proxy rule.
    func radioFaviconURL(for favicon: String?) -> URL? {
        connectionManager.apiService?.radioFaviconURL(for: favicon)
    }

    /// The identifier of the station currently playing, or nil.
    var playingRadioStationId: String? {
        guard let state, state.source == "radio", state.session?.phase == .playing,
              case .radio(let station, _) = state.details else { return nil }
        return station.id
    }

    /// The song currently playing, whatever the source, or nil if there is nothing to show.
    ///
    /// Built on `MiloAudioState.shown`, the display rule shared with Milo-iOS's lock-screen
    /// card: the session when it has a title, otherwise the resume point when it has one. So a
    /// paused source keeps its row (hiding it would make the pause button disappear right after
    /// it was pressed), and so does a stopped one that "play" would restart — a radio station
    /// after a stop, a library queue within its 600 s. A session with no title (AirPlay
    /// realtime, Bluetooth without a player, the Mac source) shows no row.
    var nowPlaying: NowPlayingInfo? {
        guard let state, isConnected else { return nil }
        return nowPlayingInfo(for: state)
    }

    /// The pure computation behind `nowPlaying`, factored out so it can be replayed on an explicit
    /// `MiloAudioState` — which is what `syncDisplayedNowPlaying` uses from `refreshState`/
    /// `didReceiveStateUpdate`, before `state` itself is necessarily up to date.
    ///
    /// Radio's only particularity is the badge: when the stream's song was recognized with its
    /// own cover art, the STATION's logo slips in over a corner of it. With no artwork of its
    /// own, the displayed cover art already IS the station's logo — doubling it up in a badge
    /// would be redundant.
    private func nowPlayingInfo(for state: MiloAudioState) -> NowPlayingInfo? {
        guard let shown = state.shown else { return nil }

        var trackId: String?
        var badgeArtworkURL: URL?
        switch state.details {
        case .musicLibrary(let id):
            trackId = id
        case .radio(let station, let track) where track?.artwork?.isEmpty == false:
            badgeArtworkURL = radioFaviconURL(for: station.favicon)
        default:
            break
        }

        return NowPlayingInfo(
            id: trackId,
            title: shown.title,
            artist: shown.artist,
            artworkURL: connectionManager.apiService?.nowPlayingArtworkURL(for: shown.artwork),
            badgeArtworkURL: badgeArtworkURL,
            isPlaying: shown.isSession && state.session?.phase == .playing
        )
    }

    /// True if the row should offer play/pause: the state lists `pause` or `resume`.
    var nowPlayingSupportsPauseResume: Bool {
        nowPlayingCanPause || state?.allows("resume") == true
    }

    /// True when the play/pause button pauses (the state lists `pause`), false when it resumes.
    /// Read from `controls` rather than from the phase, so the icon always names the command
    /// the button will actually send — `pause` is listed while loading, too.
    var nowPlayingCanPause: Bool {
        state?.allows("pause") == true
    }

    /// True if the state lists `next`.
    var nowPlayingSupportsNext: Bool {
        state?.allows("next") == true
    }

    /// True when Radio offers its stop/restart button: `stop` while loading or playing,
    /// `resume_playback` after a stop.
    var radioSupportsToggle: Bool {
        radioCanStop || state?.allows("resume_playback") == true
    }

    /// True when the Radio button stops (`stop` is listed), false when it restarts.
    var radioCanStop: Bool {
        state?.allows("stop") == true
    }

    /// Pauses or resumes the active source, whichever `controls` lists. Fire-and-forget, like
    /// the multiroom actions: the next `source/state` (WebSocket or background poll) carries the
    /// new phase and updates the row on its own — no spinner and no optimistic state here.
    func toggleNowPlayingPause() {
        guard let apiService = connectionManager.apiService, let state else { return }
        let source = state.source
        let command: String
        if state.allows("pause") {
            command = "pause"
        } else if state.allows("resume") {
            command = "resume"
        } else {
            return
        }
        Task {
            do { try await apiService.sendPlaybackCommand(command, to: source) }
            catch { NSLog("❌ Now-playing %@ (%@) failed: %@", command, source, error.localizedDescription) }
        }
    }

    /// Skips to the active source's next song, if the state lists `next`.
    func advanceToNextTrack() {
        guard let apiService = connectionManager.apiService, let state, state.allows("next") else { return }
        let source = state.source
        Task {
            do { try await apiService.sendPlaybackCommand("next", to: source) }
            catch { NSLog("❌ Now-playing next (%@) failed: %@", source, error.localizedDescription) }
        }
    }

    /// Toggles stop/restart for Radio: unlike `toggleNowPlayingPause`, this is NOT a real
    /// pause (Radio has none) — either we stop the current stream, or we restart the station
    /// the backend kept as its resume point (`resume_playback`).
    func toggleRadioNowPlaying() {
        guard let apiService = connectionManager.apiService, let state, state.source == "radio" else { return }
        if state.allows("stop") {
            stopRadioPlayback()
        } else if state.allows("resume_playback") {
            // Same spinner as a tap on the station in the list: the restart is that station.
            if case .radio(let station, _) = state.details {
                beginRadioStationLoading(stationId: station.id)
            }
            Task {
                do {
                    try await apiService.sendPlaybackCommand("resume_playback", to: "radio")
                } catch {
                    NSLog("❌ Radio resume_playback failed: %@", error.localizedDescription)
                    endRadioStationLoading()
                }
            }
        }
    }

    /// True when the Radio source is settled and its favourites can be displayed.
    var canShowRadioStations: Bool {
        state?.source == "radio"
            && state?.isSourceSettled == true
            && radioFavorites != nil
    }

    private func beginRadioStationLoading(stationId: String) {
        radioStationLoadingId = stationId
        radioStationLoadingTimer?.invalidate()

        let timer = Timer(timeInterval: radioStationLoadingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                NSLog("⏱️ Radio station loading timeout — clearing spinner")
                self?.endRadioStationLoading()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        radioStationLoadingTimer = timer
    }

    private func endRadioStationLoading() {
        guard radioStationLoadingId != nil else { return }
        radioStationLoadingId = nil
        radioStationLoadingTimer?.invalidate()
        radioStationLoadingTimer = nil
    }

    private func loadRadioFavoritesInBackground() {
        guard let apiService = connectionManager.apiService else { return }

        Task {
            do {
                let favorites = try await apiService.getRadioFavorites()
                radioFavorites = favorites
                NSLog("✅ Radio favorites loaded: %d stations", favorites.count)
            } catch {
                NSLog("❌ Failed to load radio favorites: %@", error.localizedDescription)
                radioFavorites = nil
            }
        }
    }

    // MARK: - Music library

    /// True when the Music Library source is settled: the search is done on demand,
    /// so there is nothing equivalent to `radioFavorites != nil` to wait for here.
    var canShowMusicLibrarySearch: Bool {
        state?.source == "music_library"
            && state?.isSourceSettled == true
    }

    /// Resolves a search result's cover art — the same indirection as `radioFaviconURL`.
    func musicLibraryCoverURL(for coverId: String?) -> URL? {
        connectionManager.apiService?.musicLibraryCoverURL(for: coverId)
    }

    /// Updates the typed term and (re)schedules the debounced search. An empty term clears
    /// immediately — no debounce to pay to get back to the prompt, as on the web frontend
    /// (`onInput` there short-circuits `store.clearSearch()` in the same way).
    func updateMusicLibrarySearchTerm(_ term: String) {
        musicLibrarySearchTerm = term
        musicLibrarySearchTask?.cancel()

        let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            musicLibrarySearchResults = .empty
            musicLibrarySearchHasSearched = false
            musicLibrarySearchLoading = false
            return
        }

        musicLibrarySearchLoading = true
        musicLibrarySearchTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard !Task.isCancelled else { return }
            await self?.performMusicLibrarySearch(query: trimmed)
        }
    }

    private func performMusicLibrarySearch(query: String) async {
        guard let apiService = connectionManager.apiService else { return }
        do {
            let results = try await apiService.searchMusicLibrary(query: query)
            // A late answer to a term already replaced/cleared must not overwrite
            // the current display.
            guard musicLibrarySearchTerm.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            musicLibrarySearchResults = results
            musicLibrarySearchHasSearched = true
        } catch {
            NSLog("❌ Music library search failed: %@", error.localizedDescription)
        }
        musicLibrarySearchLoading = false
    }

    /// Loads the showcase shown while the search field is empty: the recently PLAYED
    /// albums (`getAlbumList2` `type=recent`), failing that the recently ADDED albums
    /// (`type=newest`).
    ///
    /// The fallback is not a precaution on principle: Navidrome only counts a play on a
    /// `scrobble` (`submission=true`), never on the `stream` endpoint. The Milō backend has scrobbled
    /// only since 2026-09-13 — before that `recent`, `frequent` and `starred` came back
    /// empty (measured on the device), and an install whose history is still untouched finds them
    /// empty. `newest`, by contrast, derives from the import date and always answers.
    ///
    /// An album rises to the top as soon as ONE of its tracks crosses the scrobble threshold (half
    /// its duration, or 4 minutes): Navidrome propagates the track's play date to
    /// its album, and it is on that date that `recent` sorts. Listening to a whole album is therefore
    /// not necessary — verified on the device, a 9-track album ranked after a single one.
    ///
    /// The two requests are serial and not parallel: the second is only of use if the
    /// first returns nothing, which will be the case less and less often.
    func loadMusicLibraryShowcase() {
        guard let apiService = connectionManager.apiService else { return }
        musicLibraryShowcaseTask?.cancel()
        musicLibraryShowcaseLoading = true
        let size = Self.musicLibraryShowcaseSize
        musicLibraryShowcaseTask = Task { [weak self] in
            var albums: [MusicLibraryAlbum] = []
            var isRecentlyAdded = false
            do {
                albums = try await apiService.fetchMusicLibraryAlbums(type: "recent", size: size)
                if albums.isEmpty {
                    albums = try await apiService.fetchMusicLibraryAlbums(type: "newest", size: size)
                    isRecentlyAdded = true
                }
            } catch {
                NSLog("❌ Music library showcase failed: %@", error.localizedDescription)
            }
            // Cancelled = another entry into the route has taken over (or we have left it):
            // the state belongs to that one, we do not overwrite it.
            guard let self, !Task.isCancelled else { return }
            musicLibraryShowcaseAlbums = albums
            musicLibraryShowcaseIsRecentlyAdded = isRecentlyAdded
            musicLibraryShowcaseLoading = false
        }
    }

    /// True when the search sub-level renders a ScrollView rather than a single row
    /// (showcase, loading, prompt, "no results") — it is then the one that carries the panel's
    /// bottom inset, see `MiloPanelView.bottomInset(for:)`. Reproduces exactly the arbitration
    /// of `MusicLibrarySearchResultsList`, including its loading > results precedence: results
    /// still on screen during the next debounce are hidden by the spinner, and
    /// it really is a single row that is rendered at that point.
    var musicLibrarySearchShowsList: Bool {
        guard !musicLibrarySearchTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return !musicLibraryShowcaseLoading && !musicLibraryShowcaseAlbums.isEmpty
        }
        return !musicLibrarySearchLoading && !musicLibrarySearchResults.isEmpty
    }

    /// Clears all of the music library's navigation state (search AND
    /// artist/album pages) — on a full exit to the root, when the panel closes, or when
    /// the source stops being displayable (see `MiloPanelView`). NOT called by internal
    /// navigation (album → artist → search): each page keeps its own data as long as we
    /// stay within the navigation thread, `showMusicLibraryArtist`/`showMusicLibraryAlbum`
    /// overwriting them on every new visit anyway.
    func clearMusicLibraryBrowsing() {
        musicLibrarySearchTask?.cancel()
        musicLibrarySearchTerm = ""
        musicLibrarySearchResults = .empty
        musicLibrarySearchHasSearched = false
        musicLibrarySearchLoading = false

        musicLibraryShowcaseTask?.cancel()
        musicLibraryShowcaseAlbums = []
        musicLibraryShowcaseLoading = false
        musicLibraryShowcaseIsRecentlyAdded = false

        musicLibraryViewedArtist = nil
        musicLibraryArtistAlbums = []
        musicLibraryArtistAlbumsLoading = false

        musicLibraryViewedAlbum = nil
        musicLibraryAlbumSongs = []
        musicLibraryAlbumSongsLoading = false

        musicLibraryContextLoadingId = nil
        musicLibraryPlayingArtistId = nil
    }

    /// Opens an artist's page (their albums) — reachable from a search's Artists section.
    /// Loads in the background; the guard after the `await` prevents a late answer
    /// (the user has already opened ANOTHER artist in the meantime) from overwriting the right
    /// display.
    func showMusicLibraryArtist(_ artist: MusicLibraryArtist) {
        // Reopening an artist page — the same one or another — starts again from a play button, like
        // a page being discovered. A round trip to one of their albums, by contrast, does not go
        // through here and therefore keeps the queue's memory.
        musicLibraryPlayingArtistId = nil
        musicLibraryViewedArtist = artist
        musicLibraryArtistAlbums = []
        musicLibraryArtistAlbumsLoading = true
        navigate(to: .musicLibraryArtist)

        guard let apiService = connectionManager.apiService else {
            musicLibraryArtistAlbumsLoading = false
            return
        }
        Task {
            do {
                let albums = try await apiService.fetchMusicLibraryArtistAlbums(artistId: artist.id)
                guard musicLibraryViewedArtist?.id == artist.id else { return }
                musicLibraryArtistAlbums = albums
            } catch {
                NSLog("❌ Music library artist albums failed: %@", error.localizedDescription)
            }
            if musicLibraryViewedArtist?.id == artist.id { musicLibraryArtistAlbumsLoading = false }
        }
    }

    /// Opens an album's page (its songs) — reachable from a search's Albums section
    /// OR from an artist's page. The same late-answer guard as
    /// `showMusicLibraryArtist`.
    func showMusicLibraryAlbum(_ album: MusicLibraryAlbum) {
        musicLibraryViewedAlbum = album
        musicLibraryAlbumSongs = []
        musicLibraryAlbumSongsLoading = true
        navigate(to: .musicLibraryAlbum)

        guard let apiService = connectionManager.apiService else {
            musicLibraryAlbumSongsLoading = false
            return
        }
        Task {
            do {
                let songs = try await apiService.fetchMusicLibraryAlbumSongs(albumId: album.id)
                guard musicLibraryViewedAlbum?.id == album.id else { return }
                musicLibraryAlbumSongs = songs
            } catch {
                NSLog("❌ Music library album songs failed: %@", error.localizedDescription)
            }
            if musicLibraryViewedAlbum?.id == album.id { musicLibraryAlbumSongsLoading = false }
        }
    }

    /// True if THIS song is the one currently loaded by the music library (playing
    /// OR paused) — tells the "current" row from the others in a results/album
    /// list, so as to show it play/pause rather than the generic hover.
    func isCurrentMusicLibrarySong(_ song: MusicLibrarySong) -> Bool {
        state?.source == "music_library" && nowPlaying?.id == song.id
    }

    /// Starts playback of a song: the queue sent to the backend is the COMPLETE list of
    /// songs from the CONTEXT the tap came from (search results, or the open album's
    /// songs), starting at the index of the one touched — the same gesture as `playContext(songs, idx)`
    /// on the web frontend.
    func playMusicLibrarySong(_ song: MusicLibrarySong, from context: [MusicLibrarySong]) {
        guard let apiService = connectionManager.apiService,
              let index = context.firstIndex(where: { $0.id == song.id }) else { return }

        let tracks = context.map { $0.raw }
        // This queue replaces the one an artist page had started, if any.
        musicLibraryPlayingArtistId = nil
        musicLibrarySongLoadingId = song.id
        Task {
            do {
                try await apiService.playMusicLibraryContext(tracks: tracks, startIndex: index)
            } catch {
                NSLog("❌ Music library play_context failed: %@", error.localizedDescription)
            }
            musicLibrarySongLoadingId = nil
        }
    }

    /// True if the current song comes from the open album — hence whether its header's play
    /// button should toggle play/pause rather than restart the queue from the first track.
    ///
    /// We test the current song's membership of the displayed list, and not a "current album
    /// id": the backend does not publish one, and a merged multi-disc album carries a
    /// synthetic id (`mdisc:…`) that its songs do not — an id comparison
    /// would fail precisely on the albums the backend has glued back together.
    var isCurrentMusicLibraryAlbum: Bool {
        guard state?.source == "music_library", let currentId = nowPlaying?.id else { return false }
        return musicLibraryAlbumSongs.contains { $0.id == currentId }
    }

    /// True when the open album is playing (and not merely loaded): this is what
    /// decides whether the header shows pause or play.
    var isMusicLibraryAlbumPlaying: Bool {
        isCurrentMusicLibraryAlbum && (nowPlaying?.isPlaying ?? false)
    }

    /// True when the current queue is the one the open artist page started — hence when
    /// its button should toggle play/pause instead of rebuilding the queue from the start.
    var isMusicLibraryArtistQueued: Bool {
        guard state?.source == "music_library", let artist = musicLibraryViewedArtist else { return false }
        return musicLibraryPlayingArtistId == artist.id
    }

    /// True when this queue is really playing (and not merely paused): what decides whether
    /// the artist header shows pause or play.
    var isMusicLibraryArtistPlaying: Bool {
        isMusicLibraryArtistQueued && (nowPlaying?.isPlaying ?? false)
    }

    /// True when it is THIS page's queue being assembled — and not the other page's in the
    /// navigation thread, whose spinner is none of this one's business.
    var isMusicLibraryArtistPlayLoading: Bool {
        musicLibraryViewedArtist.map { musicLibraryContextLoadingId == $0.id } ?? false
    }

    var isMusicLibraryAlbumPlayLoading: Bool {
        musicLibraryViewedAlbum.map { musicLibraryContextLoadingId == $0.id } ?? false
    }

    /// Starts the open album from its first track — or toggles play/pause if it is already the
    /// one playing, the same gesture as its current song's row (`MusicLibrarySongRow`).
    ///
    /// The queue sent is the DISPLAYED list: a multi-disc album therefore goes off already concatenated
    /// in the order it is read, with nothing to glue back together here (the backend did that when serving
    /// `mdisc:…`).
    func playMusicLibraryAlbum() {
        if isCurrentMusicLibraryAlbum {
            toggleNowPlayingPause()
            return
        }

        guard let apiService = connectionManager.apiService,
              let album = musicLibraryViewedAlbum,
              !musicLibraryAlbumSongs.isEmpty else { return }

        let tracks = musicLibraryAlbumSongs.map(\.raw)
        musicLibraryPlayingArtistId = nil
        musicLibraryContextLoadingId = album.id
        Task {
            defer { if musicLibraryContextLoadingId == album.id { musicLibraryContextLoadingId = nil } }
            do {
                try await apiService.playMusicLibraryContext(tracks: tracks, startIndex: 0)
            } catch {
                NSLog("❌ Music library album play_context failed: %@", error.localizedDescription)
            }
        }
    }

    /// Starts the WHOLE open artist, their albums end to end in the page's order.
    ///
    /// The `getArtist` payload contains no tracks (it only lists albums), so
    /// the queue is assembled here: one fetch per album, all in parallel, then put back into the
    /// display order — this is the web frontend's `playAll()` gesture (ArtistView.vue), including its
    /// tolerance for albums that fail (they are skipped, we do not lose the whole queue over one).
    func playMusicLibraryArtist() {
        if isMusicLibraryArtistQueued {
            toggleNowPlayingPause()
            return
        }

        guard let apiService = connectionManager.apiService,
              let artist = musicLibraryViewedArtist,
              !musicLibraryArtistAlbums.isEmpty else { return }

        let albumIds = musicLibraryArtistAlbums.map(\.id)
        musicLibraryContextLoadingId = artist.id
        Task {
            defer { if musicLibraryContextLoadingId == artist.id { musicLibraryContextLoadingId = nil } }

            var songsByAlbum: [Int: [MusicLibrarySong]] = [:]
            await withTaskGroup(of: (Int, [MusicLibrarySong]).self) { group in
                for (index, albumId) in albumIds.enumerated() {
                    group.addTask {
                        do {
                            return (index, try await apiService.fetchMusicLibraryAlbumSongs(albumId: albumId))
                        } catch {
                            // The album is skipped, not the whole queue (as on the web). But it is
                            // logged: a truncated queue is indistinguishable from an empty album
                            // on screen, and this is where a Pi that falters under N simultaneous
                            // fetches shows itself.
                            NSLog("⚠️ Music library artist play: album %@ skipped: %@",
                                  albumId, error.localizedDescription)
                            return (index, [])
                        }
                    }
                }
                for await (index, songs) in group { songsByAlbum[index] = songs }
            }

            // The user may have opened another artist during the fetches: starting now
            // would start a queue they have already left behind (the same guard as the web's, and
            // as `showMusicLibraryArtist`'s).
            guard musicLibraryViewedArtist?.id == artist.id else { return }

            // The tasks finish out of order: it is the index that restores the order of the
            // albums as the page shows them.
            let tracks = albumIds.indices.flatMap { songsByAlbum[$0] ?? [] }.map(\.raw)
            guard !tracks.isEmpty else { return }

            do {
                try await apiService.playMusicLibraryContext(tracks: tracks, startIndex: 0)
                // Only after the send: a failure must leave the button on play, otherwise
                // it would offer to pause a queue that never started.
                musicLibraryPlayingArtistId = artist.id
            } catch {
                NSLog("❌ Music library artist play_context failed: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Multiroom

    /// True when the multiroom sub-section can be displayed: as soon as multiroom is SHOWN as
    /// active (the expected state during a toggle, the backend's otherwise). The Multiroom row's
    /// chevron and accordion follow this.
    ///
    /// Deliberately NOT gated on the registry being non-empty. The cache is emptied when
    /// multiroom goes off and only re-fetched once the backend reports it on again
    /// (`syncMultiroomState`) — so after a switch-on the list lands one round trip AFTER the
    /// spinner ends. Gated on the list, the chevron was missing in that window, and the space to
    /// the right of the label then belonged to the row's own button: a click aimed at the chevron
    /// switched multiroom back off. An empty list shows a loading row instead (see
    /// `MultiroomSection`).
    var canShowMultiroom: Bool {
        displayedToggleState("multiroom")
    }

    /// The list ordered for display: the zones (each with its member clients),
    /// then the standalone clients. Sorted online-first, zones before clients, then
    /// alphabetically — the same language as the "Output" section of "Sound" and as the
    /// multiroom web frontend.
    var multiroomDisplayItems: [MultiroomDisplayItem] {
        let clientsInZones = Set(multiroom.zones.values.flatMap { $0.clientIds })

        var items: [MultiroomDisplayItem] = []

        for zone in multiroom.zones.values {
            // We keep the members' order as the backend sorted it (local first).
            let members = zone.clientIds.compactMap { multiroom.clients[$0] }
            guard !members.isEmpty else { continue }
            items.append(.zone(zone, clients: members))
        }

        for client in multiroom.clients.values
        where client.zoneId == nil && !clientsInZones.contains(client.macId) {
            items.append(.standalone(client))
        }

        return items.sorted { lhs, rhs in
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            if lhs.isZone != rhs.isZone { return lhs.isZone }
            return lhs.sortName.localizedCaseInsensitiveCompare(rhs.sortName) == .orderedAscending
        }
    }

    /// Reloads the multiroom structure AND the live volume from the backend. Called when
    /// the sub-section opens, when multiroom becomes active, and on any structure
    /// WebSocket event. Silent on failure: we keep the last known value.
    func loadMultiroomState() {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do {
                async let structure = apiService.fetchMultiroomState()
                async let volume = apiService.fetchMultiroomVolume()
                multiroom = try await structure
                multiroomVolume = try await volume
            } catch {
                NSLog("❌ Failed to load multiroom state: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Multiroom actions (volume / mute)

    /// Sets a client's ABSOLUTE volume. Fire-and-forget: the backend rebroadcasts the new
    /// state through `volume/volume_changed`, which updates `multiroomVolume`.
    func setClientVolume(mac: String, volumeDb: Double) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do { try await apiService.setClientVolume(mac: mac, volumeDb: volumeDb) }
            catch { NSLog("❌ setClientVolume failed: %@", error.localizedDescription) }
        }
    }

    /// Toggles a client's mute.
    func setClientMute(mac: String, muted: Bool) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do { try await apiService.setClientMute(mac: mac, muted: muted) }
            catch { NSLog("❌ setClientMute failed: %@", error.localizedDescription) }
        }
    }

    /// Applies a volume DELTA to a zone (the backend passes it on to its clients).
    func setZoneVolumeDelta(zoneId: String, deltaDb: Double) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do { try await apiService.setZoneVolumeDelta(zoneId: zoneId, deltaDb: deltaDb) }
            catch { NSLog("❌ setZoneVolumeDelta failed: %@", error.localizedDescription) }
        }
    }

    /// Mutes/unmutes a whole zone — the backend has no zone endpoint for mute, so we
    /// set it client by client (like the web frontend), on the supplied MACs only.
    func setZoneMute(clientMacs: [String], muted: Bool) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            for mac in clientMacs {
                do { try await apiService.setClientMute(mac: mac, muted: muted) }
                catch { NSLog("❌ setZoneMute(%@) failed: %@", mac, error.localizedDescription) }
            }
        }
    }

    /// Keeps the multiroom cache in sync with the current state: we load it as soon as
    /// multiroom is active (and not yet loaded), and empty it when it is switched off. Called on
    /// every new state (HTTP fetch as well as WebSocket push).
    private func syncMultiroomState(for newState: MiloAudioState) {
        if newState.multiroomEnabled {
            if multiroom.clients.isEmpty { loadMultiroomState() }
        } else if !multiroom.clients.isEmpty || !multiroom.zones.isEmpty {
            multiroom = .empty
            multiroomVolume = .empty
        }
    }

    /// Keeps `displayedNowPlaying` up to date — ONLY when a song is detected, never
    /// reset to nil here: it has to stay populated after `nowPlaying` falls back to nil, long
    /// enough for `MenuBarShell` to animate `nowPlayingRevealFraction` down to 0.
    private func syncDisplayedNowPlaying(for newState: MiloAudioState) {
        if let info = nowPlayingInfo(for: newState) {
            displayedNowPlaying = info
        }
    }

    // MARK: - Loading: features (multiroom, equalizer)

    private func startFunctionalityLoading(for identifier: String, expectedState: Bool) {
        guard loadingStates[identifier] != true else { return }

        expectedFunctionalityStates[identifier] = expectedState
        loadingStartTimes[identifier] = Date()
        manualLoadingProtection[identifier] = Date()
        setLoadingState(for: identifier, isLoading: true)

        let safetyTimeout = identifier == "multiroom" ? multiroomLoadingTimeout : functionalityLoadingTimeout
        loadingTimers[identifier]?.invalidate()
        // .common mode: the safety timeout is the spinner's last-resort
        // resolution — it has to fire even during event tracking.
        let timer = Timer(timeInterval: safetyTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopFunctionalityLoading(for: identifier) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingTimers[identifier] = timer
    }

    private func stopFunctionalityLoading(for identifier: String) {
        // Minimum display duration: a toggle that answers in 80 ms must not
        // flash the spinner.
        if let startTime = loadingStartTimes[identifier] {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < minimumFunctionalityLoadingDuration {
                let remaining = minimumFunctionalityLoadingDuration - elapsed
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
                    MainActor.assumeIsolated { self?.stopFunctionalityLoading(for: identifier) }
                }
                return
            }
        }

        setLoadingState(for: identifier, isLoading: false)
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = nil
        loadingStartTimes[identifier] = nil
        manualLoadingProtection[identifier] = nil
        expectedFunctionalityStates[identifier] = nil
    }

    private func checkFunctionalityStateChange(_ newState: MiloAudioState) {
        // Multiroom: the backend pre-sets multiroom_enabled BEFORE the real routing work
        // (snapserver startup, WebSocket ready up to 15 s), so the new value alone would
        // resolve the spinner too early. But `switching` stays true for the whole switch,
        // volume sync included: the end of a multiroom switch is the first state where it is
        // false again. A stale state from before the click still carries the OLD value, so it
        // cannot match. (A refusal still arrives as multiroom_error.)
        if let expectedMultiroom = expectedFunctionalityStates["multiroom"],
           newState.multiroomEnabled == expectedMultiroom,
           !newState.switching,
           loadingStates["multiroom"] == true {
            stopFunctionalityLoading(for: "multiroom")
        }

        if let expectedEqualizer = expectedFunctionalityStates["equalizer"],
           newState.equalizerEffectsEnabled == expectedEqualizer,
           loadingStates["equalizer"] == true {
            stopFunctionalityLoading(for: "equalizer")
        }
    }

    // MARK: - Loading: audio sources

    private func startLoading(for identifier: String, timeout: TimeInterval) {
        guard loadingStates[identifier] != true else { return }

        loadingStartTimes[identifier] = Date()
        manualLoadingProtection[identifier] = Date()
        setLoadingState(for: identifier, isLoading: true)

        loadingTimers[identifier]?.invalidate()
        // .common mode — see startFunctionalityLoading.
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopLoading(for: identifier) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingTimers[identifier] = timer
    }

    private func stopLoading(for identifier: String) {
        setLoadingState(for: identifier, isLoading: false)
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = nil
        loadingStartTimes[identifier] = nil
        manualLoadingProtection[identifier] = nil
    }

    private func setLoadingState(for identifier: String, isLoading: Bool) {
        guard loadingStates[identifier] != isLoading else { return }
        loadingStates[identifier] = isLoading
    }

    /// Reconciles the source spinners with what the backend says.
    ///
    /// This is the delicate point of this class. A click sets a spinner *before* the
    /// HTTP request; the backend can take a moment to announce the transition
    /// (`switching`). During this grace window, a "non-transitional" state
    /// received is probably the **old** state (the click↔switching race) and must
    /// not clear the spinner. Once the transition is confirmed, the grace is lifted and
    /// the spinner clears as soon as the transition ends — like the web frontend.
    private func syncLoadingStatesWithBackend() {
        guard let state else { return }

        let audioSources = enabledApps?.filter { AudioSourceCatalog.allIds.contains($0) }
            ?? AudioSourceCatalog.allIds
        for identifier in audioSources {
            if state.isSourceStarting && identifier == state.source {
                // The backend has taken charge of this source's transition.
                if loadingStates[identifier] != true {
                    setLoadingState(for: identifier, isLoading: true)
                }
                // Transition confirmed: we lift the anti-race grace window so as to
                // be able to clear the spinner AS SOON AS the transition ends, without waiting
                // out a fixed delay.
                manualLoadingProtection[identifier] = nil
            } else if loadingStates[identifier] == true {
                if let graceStart = manualLoadingProtection[identifier] {
                    let elapsed = Date().timeIntervalSince(graceStart)
                    if elapsed < manualLoadingGraceDuration {
                        // Re-check at the end of the window: otherwise, if the backend
                        // emits nothing further (source already settled), the spinner
                        // would stay stuck until the safety timeout (15 s).
                        scheduleGraceWindowSourceLoadingClear(identifier, after: manualLoadingGraceDuration - elapsed)
                        continue
                    }
                }
                // Transition confirmed then finished (grace lifted), or grace
                // window expired without confirmation: we clear.
                stopLoading(for: identifier)
            }
        }
    }

    /// Re-evaluates a source's spinner at the end of its grace window when the backend
    /// has not confirmed the transition yet, by re-checking the current state (so as not to
    /// clear a transition that was taken in charge after all).
    private func scheduleGraceWindowSourceLoadingClear(_ identifier: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.loadingStates[identifier] == true, let state = self.state else { return }
                let stillTransitioning = state.isSourceStarting && identifier == state.source
                if !stillTransitioning {
                    self.stopLoading(for: identifier)
                }
            }
        }
    }

    // MARK: - Background poll

    private func startBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        consecutiveRefreshFailures = 0
        refreshPausedUntil = nil

        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: backgroundRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runBackgroundRefreshTick() }
        }
    }

    private func runBackgroundRefreshTick() {
        guard isConnected, !isPanelOpen else { return }

        // A self-recovering pause: after too many consecutive failures we wait
        // refreshPauseDuration and then retry, instead of stopping until the
        // next reconnection.
        if let pausedUntil = refreshPausedUntil {
            guard Date() >= pausedUntil else { return }
            refreshPausedUntil = nil
            consecutiveRefreshFailures = 0
        }

        // The property is owned by the main thread and nilled on disconnect.
        guard let apiService = connectionManager.apiService else { return }

        // `enabledApps` still nil = the /bulk bootstrap failed at connect. Without
        // this recovery it would only be retried on the next reconnection, and the whole
        // session would run with no source filter and no real volume limits.
        let needsBulkSettings = enabledApps == nil

        Task {
            // The volume is pushed by WebSocket in real time, no need to
            // poll it here. The static settings (dock apps + limits) are loaded
            // once at connect and then pushed by WebSocket — so we only
            // retry them while that bootstrap has not succeeded.
            if needsBulkSettings {
                await refreshBulkSettings(using: apiService)
            }

            let stateSuccess = await refreshState(using: apiService)

            if stateSuccess {
                consecutiveRefreshFailures = 0
            } else {
                consecutiveRefreshFailures += 1
                if consecutiveRefreshFailures >= maxConsecutiveFailures {
                    NSLog("⚠️ Background refresh paused after %d failures", consecutiveRefreshFailures)
                    refreshPausedUntil = Date().addingTimeInterval(refreshPauseDuration)
                }
            }
        }
    }

    private func stopBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        backgroundRefreshTimer = nil
    }

    // MARK: - Refresh

    /// Refreshes state + volume. Called when the panel opens and on connect.
    func refreshPanelData() {
        guard let apiService = connectionManager.apiService else { return }

        if consecutiveRefreshFailures >= maxConsecutiveFailures {
            NSLog("🔄 Forcing API session reset due to persistent failures")
            apiService.resetSession()
            consecutiveRefreshFailures = 0
        }

        // The /bulk bootstrap still in failure: recover it BEFORE the volume refresh, since
        // getVolumeStatus() reads the limits from the cache this fetch bootstraps.
        let needsBulkSettings = enabledApps == nil

        Task {
            if needsBulkSettings {
                await refreshBulkSettings(using: apiService)
            }

            var attempts = 0
            let maxAttempts = 2

            while attempts < maxAttempts {
                async let stateResult = refreshState(using: apiService)
                async let volumeResult = refreshVolumeStatus(using: apiService)

                let stateSuccess = await stateResult
                let volumeSuccess = await volumeResult

                if stateSuccess || volumeSuccess {
                    consecutiveRefreshFailures = 0
                    return
                }

                attempts += 1
                if attempts < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            consecutiveRefreshFailures += 1
            NSLog("⚠️ Panel refresh failed after %d attempts", maxAttempts)
        }
    }

    @discardableResult
    private func refreshState(using apiService: MiloAPIService) async -> Bool {
        do {
            let newState = try await apiService.fetchState()
            state = newState
            if newState.source == "radio" && radioFavorites == nil {
                loadRadioFavoritesInBackground()
            }
            syncMultiroomState(for: newState)
            syncDisplayedNowPlaying(for: newState)
            return true
        } catch {
            return false
        }
    }

    /// The static settings (dock apps + volume limits) through /api/settings/bulk. Also
    /// bootstraps, as a side effect on the MiloAPIService side, the limits cache read by
    /// getVolumeStatus().
    @discardableResult
    private func refreshBulkSettings(using apiService: MiloAPIService) async -> Bool {
        do {
            let settings = try await apiService.fetchBulkSettings()
            enabledApps = settings.enabledApps

            // A late bootstrap (recovery after a failed /bulk): `volume` may have been
            // read in the meantime with the fallback limits. Realign them, otherwise the slider
            // and the HUD would stay badly bounded until the next volume_limits_changed.
            // On the first bootstrap `volume` is nil: this block does nothing.
            if let existing = volume,
               existing.limitMinDb != settings.limitMinDb || existing.limitMaxDb != settings.limitMaxDb {
                let updated = existing.withLimits(minDb: settings.limitMinDb, maxDb: settings.limitMaxDb)
                volume = updated
                volumeController.setCurrentVolume(updated)
            }
            return true
        } catch {
            return false
        }
    }

    /// Bootstraps the static settings with a few spaced-out attempts, as
    /// refreshPanelData does for the state. A single failed /bulk at connect would leave
    /// `enabledApps` nil — the sources would show up with no backend filter or order —
    /// and the volume bounded to the fallback values, until the next reconnection.
    private func bootstrapBulkSettings(using apiService: MiloAPIService) async {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            if await refreshBulkSettings(using: apiService) { return }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // The last net: the background poll will retry as long as `enabledApps` is nil.
        NSLog("⚠️ Bulk settings bootstrap failed after %d attempts — background refresh will retry", maxAttempts)
    }

    @discardableResult
    private func refreshVolumeStatus(using apiService: MiloAPIService) async -> Bool {
        do {
            let volumeStatus = try await apiService.getVolumeStatus()
            updateVolumeStatus(volumeStatus)
            return true
        } catch {
            return false
        }
    }

    private func clearState() {
        state = nil
        volume = nil
        enabledApps = nil
        volumeController.apiService = nil

        // The radio cache has to be re-fetched on reconnection (the favourites may have
        // changed during the outage), and a station spinner in flight must not
        // survive the disconnection.
        radioFavorites = nil
        endRadioStationLoading()
        displayedNowPlaying = nil

        // The multiroom structure will be re-fetched on reconnection if multiroom is active.
        multiroom = .empty
        multiroomVolume = .empty

        loadingStates.keys.forEach { stopLoading(for: $0) }
        manualLoadingProtection.removeAll()
        expectedFunctionalityStates.removeAll()
    }
}

// MARK: - MiloConnectionManagerDelegate

extension MiloStore: MiloConnectionManagerDelegate {

    func miloDidConnect() {
        isConnected = true

        let apiService = connectionManager.apiService
        volumeController.apiService = apiService

        consecutiveRefreshFailures = 0
        refreshPausedUntil = nil

        // Arms the shortcuts without ever prompting: this runs as soon as Milō answers on
        // the LAN, which can be seconds after login. Asking for the Accessibility
        // permission is the panel's job, on a real click (MenuBarShell).
        //
        // `isConnected` is set above, and it is a precondition of arming — see
        // `GlobalHotkeyManager.startMonitoringIfPossible`.
        hotkeyManager?.startMonitoringIfPossible()
        startBackgroundRefresh()

        // Bootstrap the static settings cache (volume limits + dock apps) through
        // /api/settings/bulk BEFORE the first volume refresh: getVolumeStatus() reads
        // the cached limits, so this fetch has to land first to avoid a
        // window where the HUD would show the default limits (-80/-21).
        guard let apiService else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.bootstrapBulkSettings(using: apiService)
            self.refreshPanelData()
        }
    }

    func miloDidDisconnect() {
        hotkeyManager?.stopMonitoring()
        stopBackgroundRefresh()

        isConnected = false

        clearState()
        volumeController.cleanup()
    }

    func didReceiveStateUpdate(_ newState: MiloAudioState) {
        let previousSource = state?.source
        state = newState

        // Load the favourites if Radio is active and the cache is empty (whether Radio
        // was enabled from Milo Mac or from the backend).
        if newState.source == "radio" && radioFavorites == nil {
            loadRadioFavoritesInBackground()
        }

        // Clear the cache if we leave Radio.
        if newState.source != "radio" && previousSource == "radio" {
            radioFavorites = nil
            NSLog("🗑️ Radio favorites cache cleared")
        }

        // Clear the station spinner as soon as the session stops loading — covers both a
        // successful start and a failure to load the stream (the session ends), so it never
        // stays stuck. Same if Radio stops being the active source.
        if radioStationLoadingId != nil {
            if newState.source != "radio" || newState.session?.phase != .loading {
                endRadioStationLoading()
            }
        }

        checkFunctionalityStateChange(newState)
        syncLoadingStatesWithBackend()
        syncMultiroomState(for: newState)
        syncDisplayedNowPlaying(for: newState)
    }

    func didReceiveMultiroomStructureChanged() {
        // Only when multiroom is active: otherwise the sub-section is hidden and a
        // re-fetch would serve no purpose.
        guard state?.multiroomEnabled == true else { return }
        loadMultiroomState()
    }

    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume) {
        multiroomVolume = volume
    }

    func didReceiveMultiroomTransitionComplete(success: Bool) {
        guard loadingStates["multiroom"] == true else { return }
        if !success {
            // Clear the expected state on failure so that no late source/state
            // resolves it by accident.
            expectedFunctionalityStates["multiroom"] = nil
        }
        stopFunctionalityLoading(for: "multiroom")
    }

    func didReceiveVolumeUpdate(_ newVolume: VolumeStatus) {
        // The WebSocket's volume events do NOT carry the limits (the service
        // sends 0/0). Always substitute the cached limits — storing 0/0
        // would brick the slider (an empty range), notably in the window between the
        // connection and the first volume fetch where `volume` is still nil.
        let fallback = (minDb: VolumeDefaults.limitMinDb, maxDb: VolumeDefaults.limitMaxDb)
        let cached = connectionManager.apiService?.cachedLimits ?? fallback
        let limits = volume.map { (minDb: $0.limitMinDb, maxDb: $0.limitMaxDb) } ?? cached
        let updated = newVolume.withLimits(minDb: limits.minDb, maxDb: limits.maxDb)

        volume = updated
        volumeController.setCurrentVolume(updated)

        // Show the HUD on any volume change if the setting is on —
        // except while the shortcut is in use (it manages its own HUD) and except when the
        // panel is open (the user can already see the slider).
        if UserDefaults.standard.bool(forKey: DefaultsKey.showVolumeHUDOnAllChanges),
           hotkeyManager?.isActivelyAdjusting != true,
           !isPanelOpen {
            hotkeyManager?.volumeHUD?.updateLimits(minDb: updated.limitMinDb, maxDb: updated.limitMaxDb)
            hotkeyManager?.volumeHUD?.show(volumeDb: updated.volumeDb)
        }

        // `applyServerVolume` already knows to stay quiet during the shortcut and during a drag.
        applyServerVolume(updated.volumeDb)
    }

    /// The limits pushed live by the backend (settings/volume_limits_changed) when
    /// they change on the device side. We re-bootstrap the API's cache (read by
    /// getVolumeStatus) AND the in-memory limit so that the panel's slider and the
    /// shortcut's HUD immediately use the new bounds — with no /bulk re-fetch.
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double) {
        connectionManager.apiService?.updateCachedLimits(minDb: minDb, maxDb: maxDb)

        if let existing = volume {
            let updated = existing.withLimits(minDb: minDb, maxDb: maxDb)
            volume = updated
            volumeController.setCurrentVolume(updated)
        }
    }

    /// The dock apps pushed live (settings/dock_apps_changed): the sources' filter and
    /// order.
    func didReceiveDockAppsUpdate(_ apps: [String]) {
        enabledApps = apps
    }
}

// MARK: - Multiroom display item

/// One entry of the multiroom sub-section: either a zone (with the ordered list of its
/// member clients, displayed indented below it), or a standalone client.
///
/// Built on the main actor from the `MultiroomSnapshot` (see
/// `MiloStore.multiroomDisplayItems`); it does not need to be `Sendable`, it crosses
/// no isolation boundary.
enum MultiroomDisplayItem: Identifiable {
    case zone(MultiroomZone, clients: [MultiroomClient])
    case standalone(MultiroomClient)

    var id: String {
        switch self {
        case .zone(let zone, _): return "zone:\(zone.id)"
        case .standalone(let client): return "client:\(client.macId)"
        }
    }

    var isZone: Bool {
        if case .zone = self { return true }
        return false
    }

    /// Online if the item is reachable — for a zone, as soon as one of its clients is.
    var isOnline: Bool {
        switch self {
        case .zone(_, let clients): return clients.contains { $0.online }
        case .standalone(let client): return client.online
        }
    }

    var sortName: String {
        switch self {
        case .zone(let zone, _): return zone.name
        case .standalone(let client): return client.name
        }
    }
}
