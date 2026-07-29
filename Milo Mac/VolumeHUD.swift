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

/// HUD de volume du raccourci clavier.
///
/// Main-thread-only, et désormais vérifié : ses fenêtres, vues et couches sont de
/// l'AppKit pur. Les rappels de `Timer` et des moniteurs `NSEvent` sont typés
/// `@Sendable` par le SDK alors qu'ils sont posés sur la run loop principale et n'en
/// sortent jamais — d'où les `MainActor.assumeIsolated` : ils affirment au compilateur
/// ce que la run loop garantit déjà, sans différer l'exécution (un saut par `Task`
/// décalerait d'un tour la boucle d'animation à 120 Hz, et empêcherait le moniteur de
/// clic de rendre sa valeur de retour).
@MainActor
final class VolumeHUD {
    private var window: NSWindow?
    private var containerView: NSView?
    private var fillView: NSView?
    private var volumeLabel: NSTextField?
    private var hideTimer: Timer?
    private var clickMonitor: Any?

    private let windowWidth: CGFloat = 472
    private let windowHeight: CGFloat = 64
    private let sliderHeight: CGFloat = 32
    private let cornerRadius: CGFloat = 32
    // Slide distance for the show/hide animation (one HUD height)
    private let slideOffset: CGFloat = 64
    // Extra space below resting position for spring overshoot (peak ~1.148 → 12px below rest)
    private let overshootMargin: CGFloat = 16
    private(set) var isVisible = false
    private var isHiding = false
    private var animationTimer: Timer?
    private var currentOffset: CGFloat = 0

    // Police + attributs construits une seule fois : updateVolume() tourne à
    // ~33 Hz pendant un appui maintenu du raccourci, pas de lookup par tick.
    private lazy var labelFont: NSFont = {
        // Nom exact de la police (trouvé dans les informations du fichier)
        NSFont(name: "Space Mono Regular", size: 16)
            ?? NSFont.monospacedSystemFont(ofSize: 16, weight: .regular)
    }()
    private lazy var labelAttributes: [NSAttributedString.Key: Any] = [
        .font: labelFont,
        .foregroundColor: NSColor.secondaryLabelColor,
        .kern: -0.32
    ]
    private var lastRenderedText = ""

    init() {
        setupWindow()
        setupViews()
    }

    private func setupWindow() {
        // Window is tall enough to contain resting position, slide range above,
        // and overshoot margin below (spring bounces past resting position).
        let totalHeight = windowHeight + slideOffset + overshootMargin

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )

        guard let window = window else { return }

        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.backgroundColor = NSColor.clear
        // Le fond du HUD (matériau .hudWindow + overlay sombre) reste visuellement
        // sombre quel que soit le mode système. Sans forcer l'apparence, les couleurs
        // dynamiques comme secondaryLabelColor se résolvent pour un fond clair en light
        // mode et rendent le texte "-XX dB" quasi noir sur ce fond sombre.
        window.appearance = NSAppearance(named: .darkAqua)
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]

        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            // Window extends overshootMargin below HUD resting position and slideOffset above
            let windowRect = NSRect(
                x: screenRect.midX - windowWidth / 2,
                y: screenRect.maxY - windowHeight - 20 - overshootMargin,
                width: windowWidth,
                height: totalHeight
            )
            window.setFrame(windowRect, display: false)
        }

        window.alphaValue = 0

        // Le moniteur doit répondre SYNCHRONEMENT (sa valeur de retour décide si le clic
        // est avalé) : `assumeIsolated`, et non un saut par Task.
        //
        // On ne fait traverser qu'un Bool : `assumeIsolated` exige un résultat Sendable,
        // et NSEvent ne l'est pas. L'événement, lui, ne quitte jamais le main thread.
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            let swallowClick = MainActor.assumeIsolated { () -> Bool in
                guard let self = self, event.window == self.window else { return false }
                // Block clicks while the HUD is hiding (fade-out animation)
                guard !self.isHiding else { return false }
                // Only respond to clicks in the visible HUD area
                let y = event.locationInWindow.y
                guard y >= self.overshootMargin, y <= self.overshootMargin + self.windowHeight else {
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
        let totalHeight = windowHeight + slideOffset + overshootMargin

        // Transparent wrapper fills the window; containerView animates within it
        let wrapperView = NSView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: totalHeight))
        wrapperView.wantsLayer = true
        window.contentView = wrapperView

        // ContainerView rests at overshootMargin from bottom (leaving room for spring bounce below)
        // Container view (opaque wrapper for clipping + shadow)
        containerView = NSView(frame: NSRect(x: 0, y: overshootMargin, width: windowWidth, height: windowHeight))
        guard let containerView = containerView else { return }
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.masksToBounds = false
        // box-shadow: 0px 4px 32px rgba(0, 0, 0, 0.04)
        containerView.layer?.shadowColor = NSColor.black.cgColor
        containerView.layer?.shadowOpacity = 0.04
        containerView.layer?.shadowOffset = CGSize(width: 0, height: -4)
        containerView.layer?.shadowRadius = 32

        wrapperView.addSubview(containerView)

        // Backdrop blur layer (fills container, clipped to rounded rect)
        let blurView = NSVisualEffectView(frame: containerView.bounds)
        blurView.autoresizingMask = [.width, .height]
        blurView.material = .hudWindow
        blurView.blendingMode = .behindWindow
        blurView.state = .active
        blurView.wantsLayer = true
        blurView.layer?.cornerRadius = cornerRadius
        blurView.layer?.masksToBounds = true
        containerView.addSubview(blurView)

        // Semi-transparent background overlay
        let bgOverlay = NSView(frame: containerView.bounds)
        bgOverlay.autoresizingMask = [.width, .height]
        bgOverlay.wantsLayer = true
        // #767676 at 0.24 opacity
        bgOverlay.layer?.backgroundColor = NSColor(red: 0x76/255.0, green: 0x76/255.0, blue: 0x76/255.0, alpha: 0.24).cgColor
        bgOverlay.layer?.cornerRadius = cornerRadius
        containerView.addSubview(bgOverlay)

        // Gradient border (top-to-bottom white fade)
        setupGradientBorder(in: containerView)

        // Slider background
        let sliderContainer = NSView(frame: NSRect(
            x: 16, y: (windowHeight - sliderHeight) / 2,
            width: windowWidth - 32,
            height: sliderHeight
        ))
        sliderContainer.wantsLayer = true
        // #FFFFFF at 0.12 opacity
        sliderContainer.layer?.backgroundColor = NSColor(white: 1.0, alpha: 0.12).cgColor
        sliderContainer.layer?.cornerRadius = sliderHeight / 2

        containerView.addSubview(sliderContainer)

        // Fill view simple
        fillView = NSView(frame: NSRect(x: 0, y: 0, width: 0, height: sliderHeight))
        guard let fillView = fillView else { return }

        fillView.wantsLayer = true
        fillView.layer?.backgroundColor = NSColor(red: 0.09, green: 0.098, blue: 0.09, alpha: 1.0).cgColor
        fillView.layer?.cornerRadius = sliderHeight / 2

        sliderContainer.addSubview(fillView)

        // Volume label avec Space Mono
        let thinLabel = ThinTextField(labelWithString: "-60 dB")
        volumeLabel = thinLabel
        guard let volumeLabel = volumeLabel else { return }

        volumeLabel.font = labelFont
        volumeLabel.attributedStringValue = NSAttributedString(string: "-60 dB", attributes: labelAttributes)

        volumeLabel.textColor = NSColor.secondaryLabelColor
        volumeLabel.frame = NSRect(x: 14, y: (sliderHeight - 16) / 2, width: 80, height: 20.5)
        volumeLabel.alignment = .left
        volumeLabel.backgroundColor = NSColor.clear
        volumeLabel.isBordered = false

        sliderContainer.addSubview(volumeLabel)

        window.alphaValue = 0
    }

    private func setupGradientBorder(in container: NSView) {
        let borderWidth: CGFloat = 1.0
        let bounds = container.bounds

        // Dedicated overlay view so the border renders ABOVE blur + background
        let borderView = NSView(frame: bounds)
        borderView.autoresizingMask = [.width, .height]
        borderView.wantsLayer = true
        borderView.layer?.masksToBounds = false
        container.addSubview(borderView)

        let gradientLayer = CAGradientLayer()
        gradientLayer.frame = bounds
        // Conic (angular) gradient for glass effect that shines on the rounded sides
        // Starts at 12 o'clock (top), goes clockwise:
        // 0.0=top, 0.25=right curve, 0.5=bottom, 0.75=left curve, 1.0=top
        gradientLayer.type = .conic
        gradientLayer.colors = [
            NSColor(white: 1.0, alpha: 0.12).cgColor,  // top — medium
            NSColor(white: 1.0, alpha: 0.18).cgColor,  // top-right transition
            NSColor(white: 1.0, alpha: 0.28).cgColor,  // right curve — bright shine
            NSColor(white: 1.0, alpha: 0.12).cgColor,  // bottom-right transition
            NSColor(white: 1.0, alpha: 0.05).cgColor,  // bottom — dim
            NSColor(white: 1.0, alpha: 0.12).cgColor,  // bottom-left transition
            NSColor(white: 1.0, alpha: 0.28).cgColor,  // left curve — bright shine
            NSColor(white: 1.0, alpha: 0.18).cgColor,  // top-left transition
            NSColor(white: 1.0, alpha: 0.12).cgColor,  // top — close loop
        ]
        gradientLayer.locations = [0.0, 0.12, 0.25, 0.38, 0.5, 0.62, 0.75, 0.88, 1.0]
        gradientLayer.startPoint = CGPoint(x: 0.5, y: 0.5) // center of the pill

        // Mask to ring shape (rounded rect border only)
        let maskLayer = CAShapeLayer()
        let outerPath = CGPath(roundedRect: bounds, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
        let innerRect = bounds.insetBy(dx: borderWidth, dy: borderWidth)
        let innerPath = CGPath(roundedRect: innerRect, cornerWidth: cornerRadius - borderWidth, cornerHeight: cornerRadius - borderWidth, transform: nil)

        let combinedPath = CGMutablePath()
        combinedPath.addPath(outerPath)
        combinedPath.addPath(innerPath)
        maskLayer.path = combinedPath
        maskLayer.fillRule = .evenOdd

        gradientLayer.mask = maskLayer
        borderView.layer?.addSublayer(gradientLayer)
    }

    // Limites de volume en dB (peuvent être mises à jour)
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
            let screenRect = screen.visibleFrame
            let totalHeight = windowHeight + slideOffset + overshootMargin
            let windowRect = NSRect(
                x: screenRect.midX - windowWidth / 2,
                y: screenRect.maxY - windowHeight - 20 - overshootMargin,
                width: windowWidth,
                height: totalHeight
            )
            window.setFrame(windowRect, display: false)
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
              let volumeLabel = volumeLabel else { return }

        // --- Mise à jour du texte (seulement quand le dB arrondi change) ---
        let volumeText = "\(Int(round(volumeDb))) dB"
        if volumeText != lastRenderedText {
            lastRenderedText = volumeText
            volumeLabel.attributedStringValue = NSAttributedString(string: volumeText, attributes: labelAttributes)
        }

        // --- Calcul largeur/position basé sur les limites dB ---
        let sliderWidth = windowWidth - 32
        let range = limitMaxDb - limitMinDb
        let percentage = range > 0 ? (volumeDb - limitMinDb) / range : 0
        let targetWidth = CGFloat(percentage) * sliderWidth

        let fillWidth: CGFloat
        let fillX: CGFloat

        if targetWidth >= sliderHeight {
            // Cas normal
            fillWidth = targetWidth
            fillX = 0
        } else {
            // Cas spécial : largeur fixée au diamètre (cercle)
            fillWidth = sliderHeight

            // Décalage progressif vers la gauche
            let ratio = targetWidth / sliderHeight // entre 0 et 1
            let maxOffset = sliderHeight // déplacement max vers la gauche
            fillX = -(1 - ratio) * maxOffset
        }

        let targetFrame = NSRect(x: fillX, y: 0, width: fillWidth, height: sliderHeight)

        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                fillView.animator().frame = targetFrame
            }
        } else {
            // Direct update during rapid hotkey changes to avoid animation overlap glitches
            fillView.frame = targetFrame
        }
    }

    private func scheduleHide() {
        // Réutiliser le timer en repoussant son échéance : show() est appelé à
        // chaque tick du raccourci, recréer un Timer 33 fois/s est inutile.
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
                // `self.window`, et non le `window` local : la closure est @Sendable, elle
                // ne peut capturer que du Sendable — ce que VolumeHUD est (main-isolée),
                // mais pas NSWindow.
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

    // `nonisolated` : maths pures, sans état. Sans ça elles héritent du @MainActor de la
    // classe et ne peuvent plus être passées comme fonction @Sendable au timer.
    private nonisolated static let springCurveValues: [CGFloat] = [
        0, 0.0121, 0.0454, 0.0961, 0.1602, 0.2342, 0.3149, 0.3993, 0.4848, 0.5694, 0.6511, 0.7285, 0.8004, 0.866, 0.9247, 0.9761, 1.0203, 1.0572, 1.0871, 1.1105, 1.1276, 1.1391, 1.1456, 1.1477, 1.146, 1.1412, 1.1337, 1.1243, 1.1134, 1.1015, 1.089, 1.0764, 1.0639, 1.0518, 1.0404, 1.0297, 1.02, 1.0113, 1.0037, 0.9971, 0.9917, 0.9872, 0.9838, 0.9812, 0.9795, 0.9785, 0.9782, 0.9784, 0.9791, 0.9802, 0.9816, 0.9832, 0.985, 0.9868, 0.9887, 0.9905, 0.9923, 0.994, 0.9956, 0.997, 0.9983, 0.9994, 1.0004, 1.0012, 1.0019, 1.0024, 1.0028, 1.003, 1.0032, 1.0032, 1.0032, 1.0031, 1.0029, 1.0027, 1.0025, 1.0022, 1.002, 1.0017, 1.0014, 1.0011, 1.0009, 1.0007, 1.0004, 1.0003, 1.0001, 0.9999, 0.9998, 0.9997, 0.9996, 0.9996, 0.9996, 0.9995, 0.9995, 0.9995, 0.9995, 0.9996, 0.9996, 0.9996, 0.9997, 0.9997, 1
    ]

    // Des closures `@Sendable`, et non des méthodes statiques : une *référence* de méthode
    // ne se convertit pas en fonction @Sendable, or c'est sous cette forme que la boucle
    // d'animation (une closure @Sendable de Timer) les reçoit. Elles ne capturent rien.
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

        // Le timer est invalidé DEPUIS la closure @Sendable, à l'extérieur de
        // `assumeIsolated` : celle-ci n'accepte de faire traverser que du Sendable, et
        // Timer ne l'est pas. Seul un Bool « l'animation continue-t-elle ? » traverse.
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

    /// Un pas de la boucle d'animation. Renvoie `false` quand elle est terminée — ou que
    /// la fenêtre a disparu — auquel cas l'appelant invalide le timer.
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

    /// `isolated deinit` : la classe est main-only, et ce nettoyage touche fenêtre,
    /// timers et moniteur d'événements — tous main-only eux aussi.
    isolated deinit {
        if let clickMonitor = clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        hideTimer?.invalidate()
        animationTimer?.invalidate()
        window?.orderOut(nil)
    }
}
