import SwiftUI

/// The panel's content: title, slider, sources, features, footer.
///
/// Why a panel view and not an NSMenu? Because an `NSMenu` paints its own chrome — corner
/// radius and border — and no public API lets you change it. Measured: an NSMenu has
/// 14.5 pt corners and a hard border, where the system modules (Sound, Bluetooth) have
/// 18 pt corners and a soft edge. Matching them means drawing your own window.
/// See `MenuBarShell`.
struct MiloPanelView: View {
    @Bindable var store: MiloStore

    /// What the screen can display under the menu bar. Comes from `MenuBarShell`, the only one
    /// that knows which screen the panel opens on (see `PanelMetrics.maxContentHeight`).
    var maxContentHeight: CGFloat

    /// The height of the PRIMARY layer: the route displayed at rest, the OUTGOING route during a
    /// transition. Measured continuously — it is what gives the morph its starting height.
    @State private var activeHeight: CGFloat = 0

    /// The NATURAL height of the incoming layer (the one in the overlay): the morph's TARGET.
    /// Nil until it has been measured — the morph then holds its starting height, for the span
    /// of one layout pass (invisible: the curve starts out flat).
    @State private var incomingHeight: CGFloat = 0

    /// The height displayed at the moment of the click, frozen for the whole morph.
    ///
    /// A snapshot, and not `activeHeight` read live: as soon as the transition is armed, the
    /// primary layer's `fixedSize` makes its measurement jump to its NATURAL height (the station
    /// list, capped to the screen, measures all of its content at once).
    @State private var morphFromHeight: CGFloat = 0

    var body: some View {
        // During the transition, the primary layer is the one being LEFT and the incoming layer
        // is placed in an overlay. That direction, and not the other, preserves the SwiftUI
        // identity of the view being left: the station list keeps its scroll position and its
        // already-loaded logos while it fades out. (An overlay does not contribute to its host's
        // size — which suits us, the height being driven by hand here.)
        let outgoing = store.outgoingPanelRoute

        return layer(outgoing ?? store.panelRoute)
            .measuringHeight { activeHeight = $0 }
            .opacity(outgoingOpacity)
            .overlay(alignment: .top) {
                if outgoing != nil {
                    layer(store.panelRoute)
                        .measuringHeight { incomingHeight = $0 }
                        .opacity(incomingOpacity)
                }
            }
            // Height driven by hand DURING the transition only (nil at rest, where the window
            // follows the content's natural size as before).
            .frame(height: morphHeight, alignment: .top)
            // Nothing is clickable during the transition: both layers are on screen, and a
            // click on a ghost row would make no sense.
            .allowsHitTesting(!store.isRouteMorphing)
        // The panel cannot be taller than the screen. Since the window follows the content's
        // intrinsic size, it is here — and not in `positionPanel` — that the growth has to be
        // bounded: otherwise it runs off the bottom.
        //
        // The cap applies to the WHOLE content rather than to the station list alone, because
        // it is the total that has to fit. It propagates on its own to `radioContent`'s
        // ScrollView, the panel's only elastic element: measured at 40 stations (880 pt of
        // content, cap 400), the ScrollView really is SHRUNK to 357 pt — it scrolls, it does
        // not overflow. When everything fits, the cap does not take over and the height stays
        // that of the content, to the point (verified: 153 pt at 5 stations, cap or no cap).
        .frame(maxHeight: maxContentHeight, alignment: .top)
        // The content follows the panel's shape. Without this, a half-scrolled station would be
        // cut off by the ScrollView's RECTANGULAR edge: flush with the bottom edge it is the
        // same, but in the rounded corners its text would spill out of the glass. We do not rely
        // on the glass to clip — its layer is explicitly `masksToBounds = false` so the shadow
        // can get out (see `MenuBarShell.setupPanel`).
        .clipShape(RoundedRectangle(cornerRadius: PanelMetrics.cornerRadius, style: .continuous))
        // No background here: it is MenuBarShell's NSGlassEffectView that paints the glass and
        // cuts the corners. Adding one here would double it up and hide the glass.
        // The window is merely hidden (orderOut), not destroyed: `onDisappear` does not fire.
        // We reset the view to its root by observing the close, otherwise the panel would
        // reopen on the station list.
        .onChange(of: store.isPanelOpen) { _, isOpen in
            if !isOpen {
                // Back to the root WITHOUT a transition: the panel is no longer visible, and we
                // do not want to reopen on a half-played animation. Same reason for the accordion.
                store.resetPanelRoute()
                morphFromHeight = 0
                incomingHeight = 0
                store.multiroomExpanded = false
                store.multiroomRevealFraction = 0
                store.clearMusicLibraryBrowsing()
            }
        }
        .onChange(of: store.canShowRadioStations) { _, canShow in
            if !canShow, store.panelRoute == .radioStations { exitToRoot() }
        }
        .onChange(of: store.canShowMusicLibrarySearch) { _, canShow in
            if !canShow, store.panelRoute.isMusicLibrary { exitToRoot() }
        }
        // Multiroom was switched off (or the list emptied) while the sub-section
        // was open: we close it, otherwise it would stay expanded over nothing.
        .onChange(of: store.canShowMultiroom) { _, canShow in
            if !canShow { store.multiroomExpanded = false }
        }
    }

    // MARK: - Layers and transition

    /// A route's content, at its own geometry.
    ///
    /// During a transition, the layer is PINNED to its natural height (`fixedSize`) and it is the
    /// outer frame that clips it. Without this, the stations' ScrollView — the panel's only
    /// elastic element — would let itself be compressed to the interpolated height, and the
    /// measurement of its natural height (the morph's TARGET) would always equal the starting
    /// height: the panel would never move. A list taller than the screen therefore shows up
    /// during the transition clipped at its top — exactly what a scrolling list looks like at rest.
    @ViewBuilder
    private func layer(_ route: PanelRoute) -> some View {
        Group {
            switch route {
            case .root:
                // PINNED to its natural height: without it, if the window is momentarily taller
                // than the content (a slight self-sizing lag while the multiroom accordion
                // collapses), the VStack hands the surplus to the rows made vertically elastic
                // by their chevron button (`.frame(maxHeight: .infinity)`) — and the Multiroom
                // row "swelled" on close. The root content has no element that should stretch;
                // so we bound it to its ideal.
                VStack(alignment: .leading, spacing: 0) {
                    rootContent
                }
                .fixedSize(horizontal: false, vertical: true)
            case .radioStations:
                // NO `fixedSize` of its own here: the stations' ScrollView is the panel's only
                // elastic element, it has to be able to shrink in order to scroll (see the body's
                // `maxHeight` cap).
                VStack(alignment: .leading, spacing: 0) {
                    radioContent
                }
            case .musicLibrarySearch:
                // Same reason as above: the results list is the elastic element.
                VStack(alignment: .leading, spacing: 0) {
                    musicLibraryContent
                }
            case .musicLibraryArtist:
                VStack(alignment: .leading, spacing: 0) {
                    musicLibraryArtistContent
                }
            case .musicLibraryAlbum:
                VStack(alignment: .leading, spacing: 0) {
                    musicLibraryAlbumContent
                }
            }
        }
        .frame(width: MenuRowMetrics.width)
        .padding(.bottom, bottomInset(for: route))
        .fixedSize(horizontal: false, vertical: store.isRouteMorphing)
    }

    /// The route a source row's chevron should navigate to, `nil` if that source has no (or no
    /// longer any) sub-level to show — this is also what decides whether the chevron is
    /// displayed (see `showsChevron` at the call site).
    private func chevronRoute(for source: AudioSourceDescriptor) -> PanelRoute? {
        if source.id == "radio", store.canShowRadioStations { return .radioStations }
        if source.id == "music_library", store.canShowMusicLibrarySearch { return .musicLibrarySearch }
        return nil
    }

    /// Changes route, arming the morph (the timer itself lives in `MenuBarShell`).
    private func navigate(to route: PanelRoute) {
        // A snapshot taken BEFORE the switch, while the primary layer's measurement still equals
        // the DISPLAYED height (see `morphFromHeight`). `morphHeight` first: if a transition is
        // already in flight, we start again from the height reached, with no jolt.
        morphFromHeight = morphHeight ?? activeHeight
        incomingHeight = 0
        store.navigate(to: route)
    }

    /// Returns to the exact parent route (album → artist → search), the same switch as
    /// `navigate(to:)` but delegated to `MiloStore.navigateBack()`.
    private func navigateBack() {
        morphFromHeight = morphHeight ?? activeHeight
        incomingHeight = 0
        store.navigateBack()
    }

    /// A direct return to the root, stack emptied (`MiloStore.exitToRoot`) — for any back row
    /// that closes a sub-level ALL THE WAY TO THE ROOT (radio, music-library search), as
    /// opposed to `navigateBack()`, which only goes up one level (artist/album pages). A plain
    /// `navigate(to: .root)` would push the route being left for nothing: nothing would ever
    /// pop it from the root, and the stack would grow without end over a session's back-and-
    /// forths.
    private func exitToRoot() {
        morphFromHeight = morphHeight ?? activeHeight
        incomingHeight = 0
        store.exitToRoot()
    }

    /// The height imposed on the content during the transition; `nil` at rest, where the window
    /// follows the content's natural height as before.
    private var morphHeight: CGFloat? {
        guard store.isRouteMorphing, morphFromHeight > 0 else { return nil }
        // The target is the incoming layer's natural height, capped by the screen — exactly what
        // the elastic layout will give it at rest, so that the morph's last frame and the final
        // state coincide.
        let target = incomingHeight > 0 ? min(incomingHeight, maxContentHeight) : morphFromHeight
        return morphFromHeight + (target - morphFromHeight) * store.routeMorphFraction
    }

    /// The two fades barely overlap: the view being left fades out first, the new one arrives
    /// after. Superimposed halfway through, the two lists would make the panel unreadable.
    ///
    /// The thresholds apply to an ALREADY-eased fraction (the timer applies the curve): they
    /// therefore read as the morph's visual progress, not as time.
    private var outgoingOpacity: Double {
        guard store.isRouteMorphing else { return 1 }
        return Double(max(0, 1 - store.routeMorphFraction / PanelMetrics.routeFadeOutEnd))
    }

    private var incomingOpacity: Double {
        guard store.isRouteMorphing else { return 1 }
        let start = PanelMetrics.routeFadeInStart
        return Double(min(1, max(0, (store.routeMorphFraction - start) / (1 - start))))
    }

    /// Toggles the multiroom sub-section. On opening, we force a re-fetch of the structure
    /// so as to start from fresh data (a client may have come online since the connection).
    ///
    /// We ONLY flip the state: the animation is driven by `MenuBarShell`, which observes
    /// `multiroomExpanded` and varies `multiroomRevealFraction` through a timer (see the store).
    /// Definitely NO `withAnimation` here — that would report the final size in one go to
    /// `NSHostingController`, which would make the window jump.
    private func toggleMultiroom() {
        if !store.multiroomExpanded {
            store.loadMultiroomState()
        }
        store.multiroomExpanded.toggle()
    }

    /// The inset under the last row, above the panel's bottom edge.
    ///
    /// The footer (option-click) ends on text, like "Sound"; without it, the last row
    /// is Equalizer — a row with a badge, which needs a little more air.
    ///
    /// NIL in the station list: it is the ScrollView that carries this inset, inside its
    /// scrolling content (see `radioContent`). Placed here, it would have stopped the ScrollView
    /// short of the panel's edge — and a station clipped by scrolling would have been clipped
    /// leaving empty space below it, instead of disappearing under the edge.
    private func bottomInset(for route: PanelRoute) -> CGFloat {
        switch route {
        case .root:
            store.showsPreferences ? PanelMetrics.bottomInset : PanelMetrics.bottomInsetIconRow
        case .radioStations:
            stations.isEmpty ? PanelMetrics.bottomInset : 0
        case .musicLibrarySearch:
            store.musicLibrarySearchShowsList ? 0 : PanelMetrics.bottomInset
        case .musicLibraryArtist:
            store.musicLibraryArtistAlbums.isEmpty ? PanelMetrics.bottomInset : 0
        case .musicLibraryAlbum:
            store.musicLibraryAlbumSongs.isEmpty ? PanelMetrics.bottomInset : 0
        }
    }

    /// The radio favourites, in alphabetical order.
    private var stations: [RadioStation] {
        (store.radioFavorites ?? []).sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    // MARK: - Root

    @ViewBuilder
    private var rootContent: some View {
        MenuTitle(text: L("menu.title"))

        if store.isConnected {
            if let info = store.displayedNowPlaying {
                NowPlayingAccordion(store: store, info: info)
            }
            VolumeRow(store: store)

            let sources = AudioSourceCatalog.ordered(enabledApps: store.enabledApps)
            if !sources.isEmpty {
                PanelDivider()
                MenuSectionHeader(text: L("menu.audio_sources.title"))

                // The order comes from enabled_apps (backend) — never hardcoded here.
                ForEach(sources) { source in
                    let route = chevronRoute(for: source)
                    SourceRow(
                        store: store,
                        source: source,
                        showsChevron: route != nil,
                        onChevron: { if let route { navigate(to: route) } }
                    )
                }
            }

            let features = FeatureCatalog.enabled(enabledApps: store.enabledApps)
            if !features.isEmpty {
                PanelDivider()
                MenuSectionHeader(text: L("menu.features.title"))

                ForEach(features) { feature in
                    let isMultiroom = feature.id == "multiroom"
                    FeatureRow(
                        store: store,
                        feature: feature,
                        showsChevron: isMultiroom && store.canShowMultiroom,
                        isExpanded: isMultiroom && store.multiroomExpanded,
                        onChevron: isMultiroom ? { toggleMultiroom() } : nil
                    )

                    // The sub-section slides in JUST under the Multiroom row (and not at the end
                    // of the list) — the accordion opens where you clicked, as under AirPods.
                    //
                    // The Multiroom row (above) is a genuine row of the VStack: it does not
                    // move. Only the accordion below it opens/closes (see
                    // `MultiroomAccordion`). The footer (Equalizer, settings) is pushed down /
                    // pulled back by the accordion's height.
                    if isMultiroom, store.canShowMultiroom {
                        MultiroomAccordion(store: store)
                    }
                }
            }
        } else {
            DisconnectedRow()
        }

        // The footer only appears on option-click, like the old preferences menu.
        if store.showsPreferences {
            PanelDivider()
            FooterRow(title: L("config.settings")) {
                SettingsWindowPresenter.show(store: store)
            }
            FooterRow(title: L("config.quit")) {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    // MARK: - Radio stations

    @ViewBuilder
    private var radioContent: some View {
        PanelBackRow(title: L("source.radio")) { exitToRoot() }

        PanelDivider()

        if stations.isEmpty {
            RadioEmptyRow()
        } else {
            // The panel's only unbounded list — it is worth however many favourites Milō has. So
            // it scrolls as soon as it no longer fits on the screen, and thereby absorbs the cap
            // set on the body. Below that, the ScrollView is exactly its content: the panel keeps
            // its natural height, and the scroll bar does not show.
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(stations) { station in
                        RadioStationRow(store: store, station: station)
                    }
                }
            }
            // The ScrollView goes all the way down to the panel's EDGE (`bottomInset` is nil on
            // this route): the bottom inset is carried here, INSIDE the scrolling content. A
            // half-scrolled station is therefore clipped by the panel's edge, and not by an
            // inner limit that would have left empty space under the truncated text. At rest,
            // the last station gets back exactly the air it had: measured, the padding counts
            // in the ScrollView's ideal height (153 → 163 pt for 10 pt of padding).
            .contentMargins(.bottom, PanelMetrics.bottomInset, for: .scrollContent)
            // No elasticity when everything fits: without this the list bounces under the wheel
            // although there is nothing to scroll.
            .scrollBounceBehavior(.basedOnSize)
        }
    }

    // MARK: - Music library search

    @ViewBuilder
    private var musicLibraryContent: some View {
        PanelBackRow(title: L("source.music_library")) { exitToRoot() }

        PanelDivider()

        MusicLibrarySearchField(store: store)

        PanelDivider()

        MusicLibrarySearchResultsList(store: store)
    }

    // MARK: - Artist page (music library)

    @ViewBuilder
    private var musicLibraryArtistContent: some View {
        // No button as long as no album is loaded: there would be no queue to build,
        // and a button that does nothing is worth less than a button that is not there yet.
        PanelBackRow(title: store.musicLibraryViewedArtist?.name ?? "",
                     play: store.musicLibraryArtistAlbums.isEmpty ? nil : .init(
                        isLoading: store.isMusicLibraryArtistPlayLoading,
                        isPlaying: store.isMusicLibraryArtistPlaying,
                        action: { store.playMusicLibraryArtist() })) { navigateBack() }

        PanelDivider()

        MusicLibraryArtistAlbumsList(store: store)
    }

    // MARK: - Album page (music library)

    @ViewBuilder
    private var musicLibraryAlbumContent: some View {
        PanelBackRow(title: store.musicLibraryViewedAlbum?.name ?? "",
                     play: store.musicLibraryAlbumSongs.isEmpty ? nil : .init(
                        isLoading: store.isMusicLibraryAlbumPlayLoading,
                        isPlaying: store.isMusicLibraryAlbumPlaying,
                        action: { store.playMusicLibraryAlbum() })) { navigateBack() }

        PanelDivider()

        MusicLibraryAlbumSongsList(store: store)
    }
}

/// The multiroom accordion: the zones/clients sub-section whose height opens and closes.
///
/// The sub-section is ALWAYS mounted (as long as multiroom is available) and held at its
/// natural size by `fixedSize`; a GeometryReader measures its height (which depends only on the
/// number of zones/clients, never on the window — hence no loop). The container displays that
/// height MULTIPLIED by `multiroomRevealFraction` (0 collapsed → 1 expanded), animated by a
/// timer in `MenuBarShell`. `clipped()` reveals the content from the top down.
///
/// A deliberately isolated subview: it alone reads `multiroomRevealFraction`, so it alone
/// re-renders on every timer step — not the whole panel.
private struct MultiroomAccordion: View {
    @Bindable var store: MiloStore
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        MultiroomSection(store: store)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { naturalHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in naturalHeight = h }
                }
            )
            .frame(height: naturalHeight * store.multiroomRevealFraction, alignment: .top)
            .clipped()
            // A fade synchronized with the reveal: the cards appear/disappear in opacity at the
            // same time as the height opens/closes. The fraction already runs from 0 to 1 (and
            // back) along the timer's curve.
            .opacity(store.multiroomRevealFraction)
            // A click target only once it is properly open, so as not to catch a click
            // on cards that are still nearly closed.
            .allowsHitTesting(store.multiroomRevealFraction > 0.99)
    }
}

/// Collapsing/expanding the "now playing" row, the same mechanism as `MultiroomAccordion`: the
/// row stays mounted at its natural height, and a `frame(height:)` multiplied by
/// `nowPlayingRevealFraction` shows/hides it smoothly — driven by a timer in
/// `MenuBarShell`, never by `withAnimation` (see *Panel height animations* in CLAUDE.md).
///
/// Receives `store.displayedNowPlaying`, NOT `store.nowPlaying`: the latter falls back to nil as
/// soon as playback stops, before the collapse has even begun to animate — the row would lose
/// its content at the very moment it is supposed to be closing over it.
private struct NowPlayingAccordion: View {
    @Bindable var store: MiloStore
    let info: NowPlayingInfo
    @State private var naturalHeight: CGFloat = 0

    var body: some View {
        NowPlayingRow(store: store, info: info)
            .fixedSize(horizontal: false, vertical: true)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { naturalHeight = geo.size.height }
                        .onChange(of: geo.size.height) { _, h in naturalHeight = h }
                }
            )
            .frame(height: naturalHeight * store.nowPlayingRevealFraction, alignment: .top)
            .clipped()
            .opacity(store.nowPlayingRevealFraction)
            // Buttons clickable only once properly expanded — the same guard as
            // the multiroom accordion, so as not to catch a click during the collapse.
            .allowsHitTesting(store.nowPlayingRevealFraction > 0.99)
    }
}

extension View {
    /// Reports the view's height without affecting its layout — a transparent `background`
    /// proposes nothing, it merely fits its host. Same pattern as `MultiroomAccordion`.
    func measuringHeight(_ report: @escaping (CGFloat) -> Void) -> some View {
        background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { report(geo.size.height) }
                    .onChange(of: geo.size.height) { _, height in report(height) }
            }
        )
    }
}

/// A separator hairline, set on the same insets as the content.
struct PanelDivider: View {
    var body: some View {
        Divider()
            .padding(.horizontal, MenuRowMetrics.textInset)
            .padding(.vertical, 5)
    }
}

