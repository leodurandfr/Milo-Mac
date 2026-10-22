import AppKit
import Foundation
import CoreText

// NSTextField subclass that disables font smoothing for thinner rendering
// Matches -webkit-font-smoothing: antialiased behavior
private class ThinTextField: NSTextField {
    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else {
            super.draw(dirtyRect)
            return
        }
        ctx.setShouldSmoothFonts(false)
        super.draw(dirtyRect)
    }
}

/// The keyboard shortcut's volume HUD.
///
/// Main-thread-only, and now checked: its windows, views and layers are pure AppKit.
/// The `Timer` and `NSEvent` monitor callbacks are typed `@Sendable` by the SDK even
/// though they are scheduled on the main run loop and never leave it — hence the
/// `MainActor.assumeIsolated` calls: they assert to the compiler what the run loop
/// already guarantees, without deferring execution (a hop through `Task` would delay the
/// 120 Hz animation loop by a run-loop turn, and would stop the click monitor from
/// returning its value).
@MainActor
final class VolumeHUD {
    private var window: NSWindow?
    private var containerView: NSView?
    private var trackView: NSView?
    private var fillView: NSView?
    private var volumeLabel: NSTextField?
    /// The same text, over the volume label, in the fill's contrasting color — and masked to
    /// the fill's shape by `fillLabelMask`, so it only shows where the fill is.
    private var fillLabel: NSTextField?
    private let fillLabelMask = CALayer()
    private let labelX: CGFloat = 14
    private var hideTimer: Timer?
    private var clickMonitor: Any?
    private var appearanceObservation: NSKeyValueObservation?

    private let windowWidth: CGFloat = 472
    private let windowHeight: CGFloat = 64
    private let sliderHeight: CGFloat = 32
    private let cornerRadius: CGFloat = 32
    // Slide distance for the show/hide animation (one HUD height)
    private let slideOffset: CGFloat = 64
    // Extra space below resting position for spring overshoot (peak ~1.148 → 12px below rest)
    private let overshootMargin: CGFloat = 16
    // Transparent space left and right of the pill. The glass paints its rim a hair past its
    // own bounds: with the pill flush against the window's edges, the window clipped a pixel
    // off each side. Wide enough for the shadow's blur too (`shadowRadius`), as the panel does
    // with `PanelMetrics.shadowMargin`.
    private let sideMargin: CGFloat = 32
    private var totalWidth: CGFloat { windowWidth + 2 * sideMargin }
    private var totalHeight: CGFloat { windowHeight + slideOffset + overshootMargin }
    private(set) var isVisible = false
    private var isHiding = false
    private var animationTimer: Timer?
    private var currentOffset: CGFloat = 0

    // Font + attributes built once: updateVolume() runs at
    // ~33 Hz while the shortcut is held, no per-tick lookup.
    private lazy var labelFont: NSFont = {
        // The font's exact name (found in the file's info)
        NSFont(name: "Space Mono Regular", size: 16)
            ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    }()
    private lazy var labelAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: -0.32
    ]
    private lazy var fillLabelAttributes: [NSAttributedString.Key: Any] = {
        var attributes = labelAttributes
        attributes[.foregroundColor] = Self.fillLabelColor
        return attributes
    }()
    private var lastRenderedText = ""

    init() {
        setupWindow()
        setupViews()
    }

    private func setupWindow() {
        // Window is tall enough to contain resting position, slide range above,
        // and overshoot margin below (spring bounces past resting position).
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        guard let window = window else { return }

        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        Self.forceActiveAppearance(of: window)

        if let screen = NSScreen.main {
            window.setFrame(windowFrame(on: screen), display: false)
        }

        window.alphaValue = 0

        // The monitor has to answer SYNCHRONOUSLY (its return value decides whether the
        // click is swallowed): `assumeIsolated`, not a hop through Task.
        //
        // Only a Bool crosses: `assumeIsolated` requires a Sendable result,
        // and NSEvent is not. The event itself never leaves the main thread.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let swallowClick = MainActor.assumeIsolated { () -> Bool in
                guard let self = self, event.window == self.window else { return false }
                // Block clicks while the HUD is hiding (fade-out animation)
                guard !self.isHiding else { return false }
                // Only respond to clicks in the visible HUD area
                let location = event.locationInWindow
                guard location.y >= self.overshootMargin,
                      location.y <= self.overshootMargin + self.windowHeight,
                      location.x >= self.sideMargin,
                      location.x <= self.sideMargin + self.windowWidth else {
                    return false
                }
                self.hide()
                return true
            }
            return swallowClick ? nil : event
        }
    }

    private func setupViews() {
        guard let window = window else { return }

        // Transparent wrapper fills the window; containerView animates within it
        let wrapperView = NSView(frame: NSRect(x: 0, y: 0, width: totalWidth, height: totalHeight))
        wrapperView.wantsLayer = true
        window.contentView = wrapperView

        // ContainerView rests at overshootMargin from bottom (leaving room for spring bounce below)
        // Container view (opaque wrapper for clipping + shadow)
        containerView = NSView(frame: NSRect(x: sideMargin, y: overshootMargin, width: windowWidth, height: windowHeight))
        guard let containerView = containerView else { return }
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.masksToBounds = false
        // box-shadow: 0px 4px 32px rgba(0, 0, 0, 0.04)
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.04
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -4)
        containerView.layer?.shadowRadius = 32
        // An explicit path, so Core Animation does not render the whole subtree (glass
        // included) offscreen to derive the shadow from its alpha, frame after frame of the slide.
        containerView.layer?.shadowPath = CGPath(
            roundedRect: containerView.bounds,
            cornerWidth: cornerRadius,
            cornerHeight: cornerRadius,
            transform: nil
        )

        wrapperView.addSubview(containerView)

        // The pill's background: macOS 26's glass, as for the panel (see `MenuBarShell.glassView`).
        // It draws its own rim, so there is no hand-made border on top of it.
        //
        // ⚠️ Through CONSTRAINTS, and not by setting `glassView.frame`: NSGlassEffectView
        // manages its own layout and overwrites the frame it is given.
        let glassView = NSGlassEffectView()
        glassView.cornerRadius = cornerRadius
        containerView.addSubview(glassView)
        glassView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            glassView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            glassView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            glassView.topAnchor.constraint(equalTo: containerView.topAnchor),
            glassView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        // The glass hosts the slider in its contentView, which it sizes to its own bounds.
        let glassContent = NSView(frame: containerView.bounds)
        glassView.contentView = glassContent

        // Slider background
        let sliderContainer = NSView(frame: NSRect(
            x: 16, y: (windowHeight - sliderHeight) / 2,
            width: windowWidth - 32,
            height: sliderHeight
        ))
        trackView = sliderContainer
        sliderContainer.wantsLayer = true
        sliderContainer.layer?.cornerRadius = sliderHeight / 2
        // Clips the fill at low volume, when it is a circle sliding out to the left: it leaves
        // through the track's rounded end instead of spilling over the glass.
        sliderContainer.layer?.masksToBounds = true

        // A heavier blur under the track than the glass gives on its own. `.menu` adapts to
        // light and dark, like the rest of the HUD; `.active` because the window is never key,
        // and the default state would render it inactive (unblurred, flat).
        let trackBlurView = NSVisualEffectView(frame: sliderContainer.frame)
        trackBlurView.material = .menu
        trackBlurView.blendingMode = .behindWindow
        trackBlurView.state = .active
        trackBlurView.wantsLayer = true
        trackBlurView.layer?.cornerRadius = sliderHeight / 2
        trackBlurView.layer?.masksToBounds = true
        glassContent.addSubview(trackBlurView)

        glassContent.addSubview(sliderContainer)

        // Volume label, in Space Mono. BELOW the fill: the opaque fill hides it, and a copy in
        // the contrasting color sits above the fill, so the text switches color exactly at the
        // fill's edge.
        let thinLabel = ThinTextField(labelWithString: "-60 dB")
        volumeLabel = thinLabel
        guard let volumeLabel = volumeLabel else { return }
        configureLabel(volumeLabel, attributes: labelAttributes)
        sliderContainer.addSubview(volumeLabel)

        // Simple fill view
        fillView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: sliderHeight))
        guard let fillView = fillView else { return }

        fillView.wantsLayer = true
        fillView.layer?.cornerRadius = sliderHeight / 2

        sliderContainer.addSubview(fillView)

        // ⚠️ A MASK, not a clipping parent. Nested inside the fill (masksToBounds), the copy was
        // only drawn for the part of it the fill showed at the time: as the fill grew, the rest
        // never got drawn ("-71" with no " dB"). A mask leaves AppKit drawing the whole label.
        let thinFillLabel = ThinTextField(labelWithString: "-60 dB")
        fillLabel = thinFillLabel
        configureLabel(thinFillLabel, attributes: fillLabelAttributes)
        // Decorative: VoiceOver reads the volume once, from the volume label.
        thinFillLabel.setAccessibilityElement(false)
        sliderContainer.addSubview(thinFillLabel)
        thinFillLabel.wantsLayer = true
        fillLabelMask.backgroundColor = NSColor.black.cgColor
        fillLabelMask.cornerRadius = sliderHeight / 2
        fillLabelMask.frame = fillMaskFrame(for: fillView.frame, in: thinFillLabel)
        thinFillLabel.layer?.mask = fillLabelMask

        applyColors()
        // Appearance changes arrive on the main thread; the handler is typed @Sendable.
        appearanceObservation = window.observe(\.effectiveAppearance) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applyColors() }
        }
        window.alphaValue = 0
    }

    /// The window's frame on `screen`: the pill centered horizontally, 20 pt below the menu bar.
    /// The window extends `sideMargin` on each side of the pill, `overshootMargin` below its
    /// resting position and `slideOffset` above.
    private func windowFrame(on screen: NSScreen) -> NSRect {
        let screenRect = screen.visibleFrame
        return NSRect(
            x: screenRect.midX - totalWidth / 2,
            y: screenRect.maxY - windowHeight - 20 - overshootMargin,
            width: totalWidth,
            height: totalHeight
        )
    }

    /// The fill's frame (track coordinates) expressed in the fill label's own coordinates —
    /// where its mask has to sit.
    private func fillMaskFrame(for fillFrame: NSRect, in label: NSView) -> CGRect {
        fillFrame.offsetBy(dx: -label.frame.minX, dy: -label.frame.minY)
    }

    /// The two volume labels share everything but their color, and sit at the same place.
    private func configureLabel(_ label: NSTextField, attributes: [NSAttributedString.Key: Any]) {
        label.font = labelFont
        label.attributedStringValue = NSAttributedString(string: "-60 dB", attributes: attributes)
        label.frame = NSRect(x: labelX, y: (sliderHeight - 16) / 2, width: 80, height: 20.5)
        label.alignment = .left
        label.backgroundColor = NSColor.clear
        label.isBordered = false
    }

    // MARK: - Colors

    // The HUD follows the system appearance, like the panel. The fill contrasts with the glass —
    // white in dark mode, black in light mode — and the track is a veil of that same polarity.
    // The label over the track is secondaryLabelColor; its copy inside the fill takes the
    // opposite appearance's secondaryLabelColor (black at 50% / white at 55%).
    private static let trackColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(white: 1, alpha: 0.18) : NSColor(white: 0, alpha: 0.10)
    }
    private static let fillColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? .white : .black
    }
    private static let fillLabelColor = NSColor(name: nil) { appearance in
        let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        return dark ? NSColor(white: 0, alpha: 0.5) : NSColor(white: 1, alpha: 0.55)
    }

    /// Resolves the dynamic colors into the layers. A CGColor is frozen at assignment and does
    /// not follow appearance changes: this runs at setup and on every change of the window's
    /// effective appearance (`appearanceObservation`) — including while the HUD is on screen,
    /// where the labels' dynamic NSColors would otherwise switch without the fill.
    private func applyColors() {
        guard let window else { return }
        window.effectiveAppearance.performAsCurrentDrawingAppearance {
            trackView?.layer?.backgroundColor = Self.trackColor.cgColor
            fillView?.layer?.backgroundColor = Self.fillColor.cgColor
        }
    }

    // MARK: - Active glass

    /// Gives the window the active ("main") appearance without making it key or main.
    ///
    /// The glass renders in its inactive state — dull, flat, barely see-through — in a window
    /// that is not active: the reason the panel forces `makeKey()` (`MenuBarShell.showPanel`).
    /// The HUD cannot do the same: a key HUD takes the keystrokes away from the frontmost app.
    /// Nothing public says "look active" to `NSGlassEffectView` (it has no `state`, unlike
    /// `NSVisualEffectView`), so this goes through AppKit's private `_setForceMainAppearance:`.
    ///
    /// Tried and ruled out by eye, against the system's own volume bubble: `.clear` glass, and
    /// overriding `isKeyWindow`/`isMainWindow` — the glass ignores both. Overriding the private
    /// `hasKeyAppearance` family works too, but takes six overrides where this takes one call.
    ///
    /// Called once, at setup: the flag is the window's own and survives `orderOut` (checked on
    /// macOS 27 through the private `_forceMainAppearance` getter).
    ///
    /// Guarded on the method's existence AND its signature (`v20@0:8B16` — a single BOOL):
    /// should a future macOS drop it or change its argument, the HUD falls back to the inactive
    /// glass instead of calling it with the wrong ABI.
    private static func forceActiveAppearance(of window: NSWindow) {
        let selector = NSSelectorFromString("_setForceMainAppearance:")
        guard let method = class_getInstanceMethod(type(of: window), selector),
              method_getNumberOfArguments(method) == 3,
              let argumentType = method_copyArgumentType(method, 2) else { return }
        let takesBool = String(cString: argumentType) == "B"
        free(argumentType)
        guard takesBool else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(window, selector, true)
    }

    // Volume limits in dB (can be updated)
    private var limitMinDb: Double = VolumeDefaults.limitMinDb
    private var limitMaxDb: Double = VolumeDefaults.limitMaxDb

    func updateLimits(minDb: Double, maxDb: Double) {
        self.limitMinDb = minDb
        self.limitMaxDb = maxDb
    }

    func show(volumeDb: Double) {
        guard let window = window, let layer = containerView?.layer else { return }

        if isVisible {
            updateVolume(volumeDb)
            scheduleHide()
            return
        }

        // Set fill bar to correct value BEFORE showing (no animation)
        // to avoid flashing the stale value from the previous session
        updateVolume(volumeDb, animated: false)

        isVisible = true
        isHiding = false
        animationTimer?.invalidate()

        // Reposition window for current screen
        if let screen = NSScreen.main {
            window.setFrame(windowFrame(on: screen), display: false)
        }

        // Start with container translated up (off-screen)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(0, slideOffset, 0)
        CATransaction.commit()

        window.alphaValue = 0
        window.orderFrontRegardless()

        // Spring slide-down + fade-in (exact CSS `transition: all var(--transition-spring)`)
        // Both position and opacity follow the same spring curve.
        // Layer transform provides sub-pixel precision (no integer-pixel jitter).
        startAnimation(from: slideOffset, to: 0, duration: 1.2, easing: Self.springEasing, animateOpacity: (from: 0, to: 1))

        scheduleHide()
    }

    private func updateVolume(_ volumeDb: Double, animated: Bool = true) {
        guard let fillView = fillView,
              let volumeLabel = volumeLabel,
              let fillLabel = fillLabel else { return }

        // --- Text update (only when the rounded dB value changes) ---
        let volumeText = "\(Int(round(volumeDb))) dB"
        if volumeText != lastRenderedText {
            lastRenderedText = volumeText
            volumeLabel.attributedStringValue = NSAttributedString(string: volumeText, attributes: labelAttributes)
            fillLabel.attributedStringValue = NSAttributedString(string: volumeText, attributes: fillLabelAttributes)
        }

        // --- Width/position computed from the dB limits ---
        let sliderWidth = windowWidth - 32
        let range = limitMaxDb - limitMinDb
        let percentage = range > 0 ? (volumeDb - limitMinDb) / range : 0
        let targetWidth = CGFloat(percentage) * sliderWidth

        let fillWidth: CGFloat
        let fillX: CGFloat

        if targetWidth >= sliderHeight {
            // Normal case
            fillWidth = targetWidth
            fillX = 0
        } else {
            // Special case: width pinned to the diameter (a circle)
            fillWidth = sliderHeight

            // Progressive shift to the left
            let ratio = targetWidth / sliderHeight // between 0 and 1
            let maxOffset = sliderHeight // maximum shift to the left
            fillX = -(1 - ratio) * maxOffset
        }

        let targetFrame = NSRect(x: fillX, y: 0, width: fillWidth, height: sliderHeight)
        let maskFrame = fillMaskFrame(for: targetFrame, in: fillLabel)
        guard let fillLayer = fillView.layer else { return }

        // The fill and the fill label's mask must move as one, or the label's color edge drifts
        // off the fill's edge. Both are therefore animated the same way: from where they are ON
        // SCREEN right now (the presentation), to their new model frame. That matters while the
        // shortcut is held: each ~33 Hz tick interrupts the previous 0.2 s animation, and an
        // implicit action would restart from the previous TARGET instead.
        let fillFrom = Self.onScreenGeometry(of: fillLayer)
        let maskFrom = Self.onScreenGeometry(of: fillLabelMask)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillView.frame = targetFrame
        fillLabelMask.frame = maskFrame
        CATransaction.commit()

        for (layer, from) in [(fillLayer, fillFrom), (fillLabelMask, maskFrom)] {
            if animated {
                Self.slide(layer, from: from)
            } else {
                layer.removeAnimation(forKey: "bounds")
                layer.removeAnimation(forKey: "position")
            }
        }
    }

    private static let fillTimingFunction = CAMediaTimingFunction(name: .easeOut)

    private static func onScreenGeometry(of layer: CALayer) -> (bounds: CGRect, position: CGPoint) {
        let shown = layer.presentation() ?? layer
        return (shown.bounds, shown.position)
    }

    /// Animates `layer` from `from` to its current model geometry (`toValue` left nil), in 0.2 s.
    /// Re-adding under the same keys replaces an animation still in flight.
    private static func slide(_ layer: CALayer, from: (bounds: CGRect, position: CGPoint)) {
        let animations: [(String, NSValue)] = [
            ("bounds", NSValue(rect: from.bounds)),
            ("position", NSValue(point: from.position)),
        ]
        for (keyPath, fromValue) in animations {
            let animation = CABasicAnimation(keyPath: keyPath)
            animation.fromValue = fromValue
            animation.duration = 0.2
            animation.timingFunction = fillTimingFunction
            layer.add(animation, forKey: keyPath)
        }
    }

    private func scheduleHide() {
        // Reuse the timer by pushing its fire date back: show() is called on
        // every shortcut tick, recreating a Timer 33 times/s is pointless.
        if let timer = hideTimer, timer.isValid {
            timer.fireDate = Date().addingTimeInterval(3.0)
            return
        }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide(animated: Bool = true) {
        guard let window = window else { return }
        guard isVisible || isHiding else { return }

        hideTimer?.invalidate()
        hideTimer = nil
        isVisible = false

        if animated {
            isHiding = true
            // Slide up + fade out with easeInCubic (300ms) via layer transform.
            //
            // From `currentOffset`, NOT from 0: the entry spring runs for 1.2 s, so the HUD may
            // still be in flight when it is dismissed — pressing the volume hotkey, then opening
            // the panel right away (`MenuBarShell.showPanel` hides the HUD). Starting at 0 would
            // snap it back down before sliding it up.
            startAnimation(from: currentOffset, to: slideOffset, duration: 0.3, easing: Self.easeInCubic, animateOpacity: (from: 1, to: 0)) { [weak self] in
                guard let self = self, !self.isVisible else { return }
                self.isHiding = false
                // `self.window`, and not the local `window`: the closure is @Sendable, so it
                // can only capture Sendable values — which VolumeHUD is (main-isolated),
                // but NSWindow is not.
                self.window?.orderOut(nil)
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.containerView?.layer?.transform = CATransform3DIdentity
                CATransaction.commit()
            }
        } else {
            animationTimer?.invalidate()
            animationTimer = nil
            isHiding = false
            window.alphaValue = 0
            window.orderOut(nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            containerView?.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - Animation curves

    // `nonisolated`: pure, stateless maths. Without it they inherit the class's @MainActor
    // and can no longer be passed to the timer as a @Sendable function.
    private nonisolated static let springCurveValues: [CGFloat] = [
        0, 0.0121, 0.0454, 0.0961, 0.1602, 0.2342, 0.3149, 0.3993, 0.4848, 0.5694, 0.6511, 0.7285, 0.8004, 0.866, 0.9247, 0.9761, 1.0203, 1.0572, 1.0871, 1.1105, 1.1276, 1.1391, 1.1456, 1.1477, 1.146, 1.1412, 1.1337, 1.1243, 1.1134, 1.1015, 1.089, 1.0764, 1.0639, 1.0518, 1.0404, 1.0297, 1.02, 1.0113, 1.0037, 0.9971, 0.9917, 0.9872, 0.9838, 0.9812, 0.9795, 0.9785, 0.9782, 0.9784, 0.9791, 0.9802, 0.9816, 0.9832, 0.985, 0.9868, 0.9887, 0.9905, 0.9923, 0.994, 0.9956, 0.997, 0.9983, 0.9994, 1.0004, 1.0012, 1.0019, 1.0024, 1.0028, 1.003, 1.0032, 1.0032, 1.0032, 1.0031, 1.0029, 1.0027, 1.0025, 1.0022, 1.002, 1.0017, 1.0014, 1.0011, 1.0009, 1.0007, 1.0004, 1.0003, 1.0001, 0.9999, 0.9998, 0.9997, 0.9996, 0.9996, 0.9996, 0.9995, 0.9995, 0.9995, 0.9995, 0.9996, 0.9996, 0.9996, 0.9997, 0.9997, 1
    ]

    // `@Sendable` closures, and not static methods: a method *reference* does not convert
    // to a @Sendable function, and that is the form in which the animation loop (a
    // @Sendable Timer closure) receives them. They capture nothing.
    private nonisolated static let springEasing: @Sendable (CGFloat) -> CGFloat = { t in
        let maxIndex = CGFloat(springCurveValues.count - 1)
        let scaledIndex = t * maxIndex
        let lower = max(0, Int(floor(scaledIndex)))
        let upper = min(lower + 1, springCurveValues.count - 1)
        let fraction = scaledIndex - CGFloat(lower)
        return springCurveValues[lower] + (springCurveValues[upper] - springCurveValues[lower]) * fraction
    }

    private nonisolated static let easeInCubic: @Sendable (CGFloat) -> CGFloat = { $0 * $0 * $0 }

    // Animates containerView via CALayer.transform for sub-pixel smooth positioning.
    // No snap threshold needed — Core Animation handles fractional pixels natively,
    // unlike NSWindow.setFrame which rounds to integer pixels.
    private func startAnimation(from: CGFloat,
                                to: CGFloat,
                                duration: CFTimeInterval,
                                easing: @escaping @Sendable (CGFloat) -> CGFloat,
                                animateOpacity: (from: CGFloat, to: CGFloat)? = nil,
                                completion: (@MainActor @Sendable () -> Void)? = nil) {
        animationTimer?.invalidate()
        let startTime = CACurrentMediaTime()

        // The timer is invalidated FROM the @Sendable closure, outside
        // `assumeIsolated`: that call only accepts carrying Sendable values across, and
        // Timer is not. Only a Bool, "is the animation still running?", crosses.
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            let isRunning = MainActor.assumeIsolated { () -> Bool in
                self?.advanceAnimation(startTime: startTime,
                                       from: from,
                                       to: to,
                                       duration: duration,
                                       easing: easing,
                                       animateOpacity: animateOpacity,
                                       completion: completion) ?? false
            }
            if !isRunning { timer.invalidate() }
        }
    }

    /// One step of the animation loop. Returns `false` when it is done — or when the
    /// window has gone — in which case the caller invalidates the timer.
    private func advanceAnimation(startTime: CFTimeInterval,
                                  from: CGFloat,
                                  to: CGFloat,
                                  duration: CFTimeInterval,
                                  easing: @Sendable (CGFloat) -> CGFloat,
                                  animateOpacity: (from: CGFloat, to: CGFloat)?,
                                  completion: (@MainActor @Sendable () -> Void)?) -> Bool {
        guard let window, let layer = containerView?.layer else { return false }

        let elapsed = CACurrentMediaTime() - startTime
        let progress = min(CGFloat(elapsed / duration), 1.0)
        let easedProgress = easing(progress)

        currentOffset = from + (to - from) * easedProgress

        // Sub-pixel smooth positioning via Core Animation layer transform
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(0, currentOffset, 0)
        CATransaction.commit()

        // Drive opacity from the same easing curve.
        // Clamp to [0, 1] since the spring curve overshoots beyond 1.0.
        if let animateOpacity {
            let rawAlpha = animateOpacity.from + (animateOpacity.to - animateOpacity.from) * easedProgress
            window.alphaValue = min(1.0, max(0.0, rawAlpha))
        }

        guard progress >= 1.0 else { return true }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.transform = CATransform3DMakeTranslation(0, to, 0)
        CATransaction.commit()
        if let animateOpacity {
            window.alphaValue = min(1.0, max(0.0, animateOpacity.to))
        }
        animationTimer = nil
        completion?()
        return false
    }

    /// `isolated deinit`: the class is main-only, and this cleanup touches the window,
    /// the timers and the event monitor — all main-only as well.
    isolated deinit {
        if let clickMonitor = clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        hideTimer?.invalidate()
        animationTimer?.invalidate()
        window?.orderOut(nil)
    }
}
