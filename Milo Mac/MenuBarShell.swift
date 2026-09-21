import AppKit
import SwiftUI
import Observation

/// The panel's window. Borderless, it has to be able to become the key window — otherwise
/// the slider would not respond and the material would render in its "inactive" (lighter) state.
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Without this, the panel opens 60 pt too low.
    ///
    /// AppKit automatically "shoves back" any window whose top edge crosses the bottom of the
    /// menu bar. But ours is DELIBERATELY taller than the panel: it surrounds it with a
    /// transparent `shadowMargin` (60 pt) to give the shadow room to spread. Its top edge
    /// therefore goes above the top of the screen, and AppKit pushed it down by just as much.
    ///
    /// Measured, before the fix: the glass's top edge at 94.5 pt, against 34.5 pt for "Sound" —
    /// exactly the margin's 60 pt. It is the same symptom as the constraint trap documented in
    /// `setupPanel()`, but a completely different cause: here it is not the internal layout,
    /// it is the window itself that was being moved.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// A transparent container that surrounds the glass with a margin, so the drop shadow has
/// room to spread: a layer cannot draw a shadow beyond the edges of its window.
///
/// Its margins must not catch clicks — otherwise clicking "next to" the panel, in the void,
/// would not close it.
private final class ShadowContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// The menu-bar shell: an NSStatusItem that presents the SwiftUI panel in a borderless
/// window.
///
/// **Why not an NSMenu?** It was the natural route, and we tried it. But an NSMenu paints
/// its own chrome and no public API lets you change it. Measured: 14.5 pt corners and a hard
/// border, against 18 pt and a soft edge on the system modules (Sound, Bluetooth). Matching
/// them is impossible from inside a menu.
///
/// **Why not MenuBarExtra?** It takes over the NSStatusItem: we would lose control of the
/// icon (the reduced opacity when disconnected) and of option-click. Its `.menu` style does
/// render a genuine NSMenu, but it ignores images and cannot display a slider.
///
/// **Why not NSPopover?** It always draws an arrow at its anchor, and that cannot be hidden.
///
/// The price of a window: click-outside-to-dismiss, which NSMenu and NSPopover gave for
/// free, has to be rewired by hand (see below).
@MainActor
final class MenuBarShell: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let store: MiloStore

    private let panel: PanelWindow
    private let hostingController: NSHostingController<MiloPanelView>

    /// The panel's background: macOS 26's glass.
    ///
    /// And not an `NSVisualEffectView`. Measured on a solid background, the inside of the
    /// "Sound" panel reads 8 on black and 83 on white — a transmission of 0.294 over a very
    /// dark base. The best legacy material (`.toolTip`) gives 36 / 83, and no opacity setting
    /// reaches that combination: darkening a material lowers both of its values at once.
    /// Control Center therefore does not use the old material system, but Liquid Glass.
    ///
    /// ⚠️ Do NOT try the SwiftUI `.glassEffect()` modifier at the root of the view: inside a
    /// transparent NSPanel it renders the whole window invisible, content included (verified:
    /// window visible, alpha 1, but painting nothing). The AppKit view is what is required,
    /// with the SwiftUI view placed in its `contentView`.
    private let glassView = NSGlassEffectView()

    /// Watches for clicks outside the panel in order to close it.
    private var outsideClickMonitor: Any?

    /// True during the fade-out. The window is still "visible" at that point.
    private var isHiding = false

    /// SCREEN y-coordinate of the panel's TOP edge (`origin.y + height`), set by `positionPanel`.
    ///
    /// The panel is pinned under the menu bar and must only grow/shrink DOWNWARDS.
    /// During the multiroom accordion it is `stepReveal` that resets the frame at every step (the
    /// top is already right). But `NSHostingController` can ALSO resize the window on its own
    /// when the content changes at rest (a client comes online): AppKit then keeps the bottom-left
    /// corner and makes the top edge rise under the bar. `windowDidResize` pins it back to this
    /// value — a plain origin shift, without touching the height (hence no loop).
    private var pinnedTopY: CGFloat?

    init(store: MiloStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The height ceiling is re-evaluated on every opening (`positionPanel`), since the screen
        // can change; the one here is only a starting value.
        self.hostingController = NSHostingController(
            rootView: MiloPanelView(
                store: store,
                maxContentHeight: PanelMetrics.maxContentHeight(on: NSScreen.main)
            )
        )

        self.panel = PanelWindow(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        super.init()

        setupStatusItem()
        setupPanel()
        observeConnection()
        observeMultiroomExpansion()
        observePanelNavigation()
        observeStateForRepositioning()
        observeMusicLibrarySearchForRepositioning()
        updateIcon()
    }

    // MARK: - Status item

    private func setupStatusItem() {
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
    }

    private func menuBarIcon() -> NSImage? {
        if let image = NSImage(named: "menubar-icon") {
            image.isTemplate = true
            image.size = NSSize(width: 22, height: 22)
            return image
        }

        let fallback = NSImage(systemSymbolName: "speaker.wave.3",
                               accessibilityDescription: L("accessibility.milo_icon"))
        fallback?.isTemplate = true
        return fallback
    }

    /// The historical behaviour, preserved as is: the icon is half transparent
    /// as long as Milō is unreachable.
    private func updateIcon() {
        statusItem.button?.alphaValue = store.isConnected ? 1.0 : 0.5
    }

    /// `@Observable` only notifies once per observation: it has to be re-armed on every
    /// change, otherwise the icon updates only once.
    private func observeConnection() {
        withObservationTracking {
            _ = store.isConnected
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.updateIcon()
                self.observeConnection()
            }
        }
    }

    // MARK: - State-driven content

    /// True if the "now playing" row was visible in the last observed state — so that
    /// `animateNowPlayingReveal` only fires on a real change of PRESENCE (music detected or
    /// not), not on every broadcast that touches `state` without touching it (the volume, say).
    private var lastNowPlayingPresence = false

    /// Resets the panel to the real size of its content on every new state, as long as it is
    /// open. Same re-arming pattern as `observeConnection`.
    ///
    /// Two cases: the "now playing" row appears or disappears (source change, playback stopped) —
    /// smoothly animated by `animateNowPlayingReveal`, like the multiroom accordion.
    /// Everything else (source list, connection…) has no dedicated timer: `NSHostingController`
    /// grows the window on its own when the content gets longer, but never SHRINKS it when it
    /// gets shorter (see `stepReveal`) — without this immediate reset, content shrinking at rest
    /// left a gap under the panel.
    private func observeStateForRepositioning() {
        withObservationTracking {
            _ = store.state
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                let isNowPlayingVisible = self.store.nowPlaying != nil
                if isNowPlayingVisible != self.lastNowPlayingPresence {
                    self.lastNowPlayingPresence = isNowPlayingVisible
                    self.animateNowPlayingReveal(to: isNowPlayingVisible ? 1 : 0)
                } else if self.panel.isVisible {
                    self.positionPanel()
                }
                self.observeStateForRepositioning()
            }
        }
    }

    /// Resets the panel on every new search keystroke OR new artist/album page,
    /// independently of any route transition: unlike the radio station list
    /// (which only changes shape when its route opens/closes, handled by the morph),
    /// this content changes shape AFTER entering the route (a keystroke changes the
    /// results; the artist/album page arrives empty - loading - then fills once the network
    /// response comes back) — deleting text, or watching a list fill in afterwards, can
    /// SHRINK/grow with no route change at all, and `NSHostingController` never shrinks
    /// the window by itself.
    ///
    /// The `!isRouteMorphing` guard avoids fighting the morph timer's `positionPanel()` calls
    /// while entering/leaving the route itself.
    private func observeMusicLibrarySearchForRepositioning() {
        withObservationTracking {
            _ = store.musicLibrarySearchResults
            _ = store.musicLibrarySearchLoading
            _ = store.musicLibraryArtistAlbums
            _ = store.musicLibraryArtistAlbumsLoading
            _ = store.musicLibraryAlbumSongs
            _ = store.musicLibraryAlbumSongsLoading
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.panel.isVisible, !self.store.isRouteMorphing {
                    self.positionPanel()
                }
                self.observeMusicLibrarySearchForRepositioning()
            }
        }
    }

    // MARK: - "Now playing" row

    private var nowPlayingRevealTimer: Timer?
    private var nowPlayingRevealStartFraction: CGFloat = 0
    private var nowPlayingRevealTargetFraction: CGFloat = 0
    private var nowPlayingRevealStartTime: CFTimeInterval = 0
    /// Shorter than the multiroom accordion (0.45 s): a single row to reveal, not a
    /// sub-section of cards — any longer and the appearance would drag.
    private let nowPlayingRevealDuration: CFTimeInterval = 0.3

    /// Animates `nowPlayingRevealFraction` towards `target`. Same construction as `animateReveal`
    /// (multiroom accordion): a 120 Hz timer that resets the window at every step, never
    /// `withAnimation` (see *Panel height animations* in CLAUDE.md).
    private func animateNowPlayingReveal(to target: CGFloat) {
        nowPlayingRevealTimer?.invalidate()

        // Panel hidden: nothing to animate, we set the final state — like the route morph.
        guard panel.isVisible else {
            store.nowPlayingRevealFraction = target
            return
        }

        nowPlayingRevealStartFraction = store.nowPlayingRevealFraction
        nowPlayingRevealTargetFraction = target
        nowPlayingRevealStartTime = CACurrentMediaTime()

        guard nowPlayingRevealStartFraction != target else {
            store.nowPlayingRevealFraction = target
            return
        }

        nowPlayingRevealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            let running = MainActor.assumeIsolated { self?.stepNowPlayingReveal() ?? false }
            if !running { timer.invalidate() }
        }
    }

    private func stepNowPlayingReveal() -> Bool {
        let raw = (CACurrentMediaTime() - nowPlayingRevealStartTime) / nowPlayingRevealDuration
        let t = min(CGFloat(raw), 1)
        let e = Self.ease(t)
        store.nowPlayingRevealFraction = nowPlayingRevealStartFraction
            + (nowPlayingRevealTargetFraction - nowPlayingRevealStartFraction) * e
        // See `stepReveal`: `NSHostingController`'s self-sizing grows the window
        // on its own but never shrinks it — it has to be reset at every step.
        if panel.isVisible { positionPanel() }

        guard t >= 1 else { return true }
        store.nowPlayingRevealFraction = nowPlayingRevealTargetFraction
        if panel.isVisible { positionPanel() }
        nowPlayingRevealTimer = nil
        return false
    }

    // MARK: - Multiroom accordion

    /// Animates `multiroomRevealFraction` on every toggle of `multiroomExpanded`. Same re-arming
    /// pattern as `observeConnection`.
    ///
    /// This is a timer (concrete values 120 times/s), and NOT `withAnimation`: each step gives
    /// the SwiftUI content a concrete height, on which `stepReveal` immediately resets the
    /// window (see `positionPanel`), the glass following on its own. `withAnimation`, by
    /// contrast, would report the FINAL size to `NSHostingController` in one go (which would
    /// resize the window in one block): the window would jump, content centred mid-transition.
    private func observeMultiroomExpansion() {
        withObservationTracking {
            _ = store.multiroomExpanded
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                self.animateReveal(to: self.store.multiroomExpanded ? 1 : 0)
                self.observeMultiroomExpansion()
            }
        }
    }

    private var revealTimer: Timer?
    private var revealStartFraction: CGFloat = 0
    private var revealTargetFraction: CGFloat = 0
    private var revealStartTime: CFTimeInterval = 0
    private let revealDuration: CFTimeInterval = 0.45

    private func animateReveal(to target: CGFloat) {
        revealTimer?.invalidate()
        revealStartFraction = store.multiroomRevealFraction
        revealTargetFraction = target
        revealStartTime = CACurrentMediaTime()

        guard revealStartFraction != target else {
            store.multiroomRevealFraction = target
            return
        }

        // The same idiom as the volume HUD's animation: a 120 Hz `Timer`, `CACurrentMediaTime`
        // for the clock, `MainActor.assumeIsolated` to cross back to the main actor (the timer
        // does arrive on the main thread, but its type cannot say so).
        revealTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            let running = MainActor.assumeIsolated { self?.stepReveal() ?? false }
            if !running { timer.invalidate() }
        }
    }

    /// Cubic easeInOut, the curve of every panel height animation.
    private static func ease(_ t: CGFloat) -> CGFloat {
        t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
    }

    private func stepReveal() -> Bool {
        let raw = (CACurrentMediaTime() - revealStartTime) / revealDuration
        let t = min(CGFloat(raw), 1)
        let e = Self.ease(t)
        store.multiroomRevealFraction = revealStartFraction + (revealTargetFraction - revealStartFraction) * e
        // We reset the window to the REAL size of the content at this step. Indispensable:
        // `NSHostingController`'s self-sizing enlarges the window when the content grows,
        // but does not SHRINK it when the content shrinks (the intrinsic constraint pushes
        // upwards, never downwards). Without this reset, the window would stay tall on close.
        // `positionPanel` measures the content and pins it back under the menu bar.
        if panel.isVisible { positionPanel() }

        guard t >= 1 else { return true }
        store.multiroomRevealFraction = revealTargetFraction
        if panel.isVisible { positionPanel() }
        revealTimer = nil
        return false
    }

    // MARK: - Route morphing (root ↔ radio stations)

    /// Animates the switch from one route to another. We observe `outgoingPanelRoute` and not
    /// `panelRoute`: only it tells a NAVIGATION (clicking the Radio chevron, going back) apart
    /// from a plain return to the root when the panel closes, which must not be animated.
    /// Same re-arming pattern as `observeConnection`.
    private func observePanelNavigation() {
        withObservationTracking {
            _ = store.outgoingPanelRoute
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                if self.store.isRouteMorphing {
                    self.animateRouteMorph()
                } else {
                    self.routeMorphTimer?.invalidate()
                    self.routeMorphTimer = nil
                }
                self.observePanelNavigation()
            }
        }
    }

    private var routeMorphTimer: Timer?
    private var routeMorphStartTime: CFTimeInterval = 0

    /// Shorter than the multiroom accordion (0.45 s): that one unfolds content under a row just
    /// pointed at, this one CHANGES view — any longer and navigation drags.
    private let routeMorphDuration: CFTimeInterval = 0.34

    private func animateRouteMorph() {
        routeMorphTimer?.invalidate()

        // Panel hidden: nothing to animate, we set the final state.
        guard panel.isVisible else {
            store.finishRouteMorph()
            return
        }

        store.routeMorphFraction = 0
        routeMorphStartTime = CACurrentMediaTime()

        // The same idiom as the accordion: a 120 Hz timer rather than a `withAnimation`, so that
        // the SwiftUI content has a CONCRETE height at every step that the window can follow.
        routeMorphTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            let running = MainActor.assumeIsolated { self?.stepRouteMorph() ?? false }
            if !running { timer.invalidate() }
        }
    }

    private func stepRouteMorph() -> Bool {
        let raw = (CACurrentMediaTime() - routeMorphStartTime) / routeMorphDuration
        let t = min(CGFloat(raw), 1)
        store.routeMorphFraction = Self.ease(t)
        // As for the accordion: `NSHostingController` GROWS the window on its own, but
        // never shrinks it — it has to be reset at every step to the content's real height
        // (a navigation goes towards a taller view as readily as towards a shorter one).
        if panel.isVisible { positionPanel() }

        guard t >= 1 else { return true }
        store.finishRouteMorph()
        if panel.isVisible { positionPanel() }
        routeMorphTimer = nil
        return false
    }

    // MARK: - Panel

    private func setupPanel() {
        // The glass carries the SwiftUI content and defines the panel's shape.
        glassView.contentView = hostingController.view
        glassView.cornerRadius = PanelMetrics.cornerRadius

        // A hand-drawn shadow. NSWindow's is not adjustable and turns out to be far too
        // tight: measured on a white background, it reaches 15.5 pt and darkens by 72 at the
        // edge, where "Sound"'s reaches 48.5 pt darkening by only 48 — three times wider and
        // far softer.
        glassView.wantsLayer = true
        glassView.layer?.masksToBounds = false
        glassView.layer?.shadowColor = NSColor.black.cgColor
        glassView.layer?.shadowOpacity = PanelMetrics.shadowOpacity
        glassView.layer?.shadowRadius = PanelMetrics.shadowRadius
        glassView.layer?.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowOffsetY)

        // A layer cannot draw a shadow beyond the edges of its window: the glass is therefore
        // embedded in a larger container, whose transparent margins let the shadow spread.
        //
        // ⚠️ Through CONSTRAINTS, and not by setting `glassView.frame`: NSGlassEffectView
        // manages its contentView's layout and overwrites the frame it is given. The glass then
        // ended up flush with the bottom of the container, the whole margin went above it, and
        // the panel opened 60 pt too low under the menu bar.
        let container = ShadowContainerView()
        container.addSubview(glassView)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        let m = PanelMetrics.shadowMargin
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: m),
            glassView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -m),
            glassView.topAnchor.constraint(equalTo: container.topAnchor, constant: m),
            glassView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -m)
        ])

        panel.contentView = container
        panel.delegate = self

        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false

        panel.level = .popUpMenu
        panel.hidesOnDeactivate = false
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        // No scaling: appearing and disappearing are plain fades,
        // driven by hand in showPanel/hidePanel.
        panel.animationBehavior = .none
    }

    @objc private func statusItemClicked() {
        // Panel visible: this click is a toggle to "closed". Including when it is ALREADY
        // closing — because it is often that same click that closed it: on a real click, the
        // mouse-down makes it lose focus (`windowDidResignKey` → `hidePanel`) BEFORE the
        // mouse-up triggers this action. So we let the close run to completion instead of
        // reopening (otherwise the icon never closed the panel).
        if panel.isVisible {
            if !isHiding { hidePanel() }
            return
        }

        // Option-click: the panel opens with its footer (Settings, Quit).
        //
        // We read the LIVE modifier state (`NSEvent.modifierFlags`), and not the ones carried
        // by `NSApp.currentEvent`: on an NSStatusItem's action, the mouse-up event arrives with
        // empty `modifierFlags` (verified: option held down, `currentEvent` at 0, global state
        // at `.option`). Relying on it left the footer invisible.
        store.showsPreferences = NSEvent.modifierFlags.contains(.option)

        showPanel()
    }

    private func showPanel() {
        // The keyboard shortcut's HUD floats above everything: hide it so it does not
        // cover the panel that has just been opened.
        store.hotkeyManager?.volumeHUD?.hide()

        store.isPanelOpen = true
        store.refreshPanelData()

        // The "now playing" row starts from the REAL state, with no animation: we have just
        // opened, there is nothing to slide. Only changes occurring WHILE the panel is open
        // (`observeStateForRepositioning`) are animated.
        nowPlayingRevealTimer?.invalidate()
        lastNowPlayingPresence = store.nowPlaying != nil
        store.nowPlayingRevealFraction = lastNowPlayingPresence ? 1 : 0

        positionPanel()

        // The app is in .accessory policy: it is not active when clicking in the menu bar,
        // so the window would open **non-key** and its material would render in its
        // "inactive" state (visibly lighter). Activating BEFORE the show is not enough —
        // the activation has not taken effect yet when the window is created.
        isHiding = false
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        // Like "Sound": the appearance is brisk, the disappearance slower.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = PanelMetrics.fadeInDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }

        startWatchingOutsideClicks()
    }

    private func hidePanel() {
        guard !isHiding else { return }
        isHiding = true

        stopWatchingOutsideClicks()
        store.isPanelOpen = false

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = PanelMetrics.fadeOutDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            // The completion closure is not isolated to the main actor: we come back to it
            // explicitly rather than touching `isHiding` there directly.
            Task { @MainActor in
                guard let self, self.isHiding else { return }
                self.panel.orderOut(nil)
                self.isHiding = false
            }
        })
    }

    /// The transparent margin to the left of the ink, WITHIN the icon's image. Measured once
    /// rather than hardcoded: if the asset changes, the panel's alignment follows.
    private var cachedIconInkInset: CGFloat?

    /// The x-coordinate of the icon's first VISIBLE pixel, in screen coordinates.
    ///
    /// An NSStatusItem's button centres its image, and the image itself has empty space around
    /// its drawing. The two add up: our button is 40 pt, the image 22, the ink 14 — so the ink
    /// starts 13 pt from the button's edge. "Sound"'s is fitted to its glyph (ink 1.5 pt from
    /// the edge). Anchoring on the button's FRAME, as the system does, would shift us by
    /// 11.5 pt: so we anchor on the ink.
    private func iconInkMinX(button: NSStatusBarButton, buttonRect: NSRect) -> CGFloat {
        guard let image = button.image else { return buttonRect.minX }

        let inkInset: CGFloat
        if let cachedIconInkInset {
            inkInset = cachedIconInkInset
        } else {
            inkInset = Self.leftInkInset(of: image)
            cachedIconInkInset = inkInset
        }

        // The image is centred in the button.
        let imageMinX = buttonRect.minX + (buttonRect.width - image.size.width) / 2
        return imageMinX + inkInset
    }

    /// The image's first non-transparent column.
    private static func leftInkInset(of image: NSImage) -> CGFloat {
        let w = Int(image.size.width.rounded())
        let h = Int(image.size.height.rounded())
        guard w > 0, h > 0,
              let rep = NSBitmapImageRep(
                  bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h,
                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                  colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        else { return 0 }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
        NSGraphicsContext.restoreGraphicsState()

        for x in 0..<w {
            for y in 0..<h where (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
                return CGFloat(x)
            }
        }
        return 0
    }

    /// Places the panel under the icon, left-aligned with it, without running off the screen.
    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // What the screen can display. The content caps itself to it (the station list scrolls
        // beyond that): so it has to be told BEFORE being measured. We only rewrite the view
        // if the value has moved — otherwise we would invalidate the layout on every opening.
        let maxContentHeight = PanelMetrics.maxContentHeight(on: screen)
        if hostingController.rootView.maxContentHeight != maxContentHeight {
            hostingController.rootView.maxContentHeight = maxContentHeight
        }

        // The size comes from the SwiftUI content: it changes depending on whether the footer
        // is visible, whether Milō is connected, whether we are in the radio station list, or
        // whether the multiroom sub-section is expanded.
        hostingController.view.layoutSubtreeIfNeeded()
        var size = hostingController.view.fittingSize

        // A WHOLE height, indispensable for sub-pixel alignment: see `shadowMargin`, whose
        // 60.5 pt only land right if the content height is an integer. Without this rounding,
        // the panel drifted by a pixel depending on the parity of its content.
        size.height = min(size.height.rounded(.up), maxContentHeight)

        hostingController.view.frame = NSRect(origin: .zero, size: size)

        // The window is larger than the panel: the margin houses the shadow. The glass is
        // centred in it by the constraints set in setupPanel().
        let m = PanelMetrics.shadowMargin

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        // We position the PANEL, then offset the window by the margin.
        //
        // LEFT-aligned with the icon, and not centred under it: that is what the system
        // modules do. Measured on "Sound": its panel starts 11.5 pt left of its glyph's ink —
        // its badges (14 pt from the edge) then land 2.5 pt right of the ink, the optical
        // alignment the eye reads as "aligned".
        var x = iconInkMinX(button: button, buttonRect: buttonRect) - PanelMetrics.panelLeftFromIconInk
        let visible = screen.visibleFrame
        x = min(max(x, visible.minX + PanelMetrics.screenEdgeMargin),
                visible.maxX - size.width - PanelMetrics.screenEdgeMargin)

        // Anchored on the bottom of the MENU BAR (`visibleFrame.maxY`), and not on the bottom
        // of the button: on a notched screen the bar is taller than the status item, and
        // anchoring on the button makes the panel overlap under the bar. The panel therefore
        // grows DOWNWARDS (the top stays pinned under the bar), like "Sound".
        let y = visible.maxY - PanelMetrics.topGap - size.height

        let frame = NSRect(x: x - m, y: y - m,
                           width: size.width + 2 * m, height: size.height + 2 * m)
        // We pin the top edge BEFORE setting the frame: the `setFrame` triggers `windowDidResize`,
        // which must already know the right value (otherwise it would reset to the old one).
        pinnedTopY = frame.origin.y + frame.height
        panel.setFrame(frame, display: false)
    }

    // MARK: - Click-outside-to-dismiss

    /// `NSMenu` and `NSPopover.behavior = .transient` did this on their own. With a
    /// window, you have to watch for clicks elsewhere yourself — including in other
    /// applications, hence the **global** monitor.
    private func startWatchingOutsideClicks() {
        stopWatchingOutsideClicks()

        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            Task { @MainActor in self?.hidePanel() }
        }
    }

    private func stopWatchingOutsideClicks() {
        if let outsideClickMonitor {
            NSEvent.removeMonitor(outsideClickMonitor)
        }
        outsideClickMonitor = nil
    }

    // MARK: - NSWindowDelegate

    /// The panel loses focus (Cmd-Tab, another app, Settings opening): we close it,
    /// as Sound and Bluetooth do.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        hidePanel()
    }

    /// `NSHostingController` resizes the window to the SwiftUI content's size (expanding/collapsing
    /// the multiroom accordion). AppKit then keeps the bottom-left corner fixed, which would make
    /// the top edge rise under the menu bar: we pin it back to `pinnedTopY` by moving only the
    /// origin (never the height — so no resize loop). See `pinnedTopY`.
    func windowDidResize(_ notification: Notification) {
        guard let top = pinnedTopY else { return }
        let newY = top - panel.frame.height
        if abs(panel.frame.origin.y - newY) > 0.01 {
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: newY))
        }
    }
}
