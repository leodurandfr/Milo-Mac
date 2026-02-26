import AppKit
import Foundation
import CoreText

class VolumeHUD {
    private var window: NSWindow?
    private var containerView: NSVisualEffectView?
    private var fillView: NSView?
    private var volumeLabel: NSTextField?
    private var hideTimer: Timer?
    private var clickMonitor: Any?

    private let windowWidth: CGFloat = 472
    private let windowHeight: CGFloat = 64
    private let sliderHeight: CGFloat = 32
    private let cornerRadius: CGFloat = 32
    // Match CSS translateY(-80px) exactly for identical spring feel
    private let slideOffset: CGFloat = 64
    // Extra space below resting position for spring overshoot (peak ~1.148 → 12px below rest)
    private let overshootMargin: CGFloat = 16
    private(set) var isVisible = false
    private var animationTimer: Timer?
    private var currentOffset: CGFloat = 0

    init() {
        setupWindow()
        setupViews()
    }

    // Fonction pour obtenir la police Space Mono
    private func getSpaceMonoFont(size: CGFloat) -> NSFont {
        // Nom exact de la police (trouvé dans les informations du fichier)
        if let font = NSFont(name: "Space Mono Regular", size: size) {
            return font
        }

        print("⚠️ Space Mono non trouvée, utilisation de la police système monospace")
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
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

        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self = self, event.window == self.window else { return event }
            // Only respond to clicks in the visible HUD area
            let y = event.locationInWindow.y
            if y >= self.overshootMargin && y <= self.overshootMargin + self.windowHeight {
                self.hide()
                return nil
            }
            return event
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
        containerView = NSVisualEffectView(frame: NSRect(x: 0, y: overshootMargin, width: windowWidth, height: windowHeight))
        guard let containerView = containerView else { return }

        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.borderWidth = 2
        containerView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor

        wrapperView.addSubview(containerView)

        // Slider background
        let sliderContainer = NSView(frame: NSRect(
            x: 16, y: (windowHeight - sliderHeight) / 2,
            width: windowWidth - 32,
            height: sliderHeight
        ))
        sliderContainer.wantsLayer = true
        sliderContainer.layer?.backgroundColor = NSColor(red: 1.0, green: 1.0, blue: 1.0, alpha: 0.16).cgColor
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
        volumeLabel = NSTextField(labelWithString: "-60 dB")
        guard let volumeLabel = volumeLabel else { return }

        let spaceMonoFont = getSpaceMonoFont(size: 16)
        volumeLabel.font = spaceMonoFont

        let attributedString = NSMutableAttributedString(string: "-60 dB")
        attributedString.addAttribute(.font, value: spaceMonoFont, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.kern, value: -0.32, range: NSRange(location: 0, length: attributedString.length))
        volumeLabel.attributedStringValue = attributedString

        volumeLabel.textColor = NSColor.secondaryLabelColor
        volumeLabel.frame = NSRect(x: 14, y: (sliderHeight - 16) / 2, width: 80, height: 20.5)
        volumeLabel.alignment = .left
        volumeLabel.backgroundColor = NSColor.clear
        volumeLabel.isBordered = false

        sliderContainer.addSubview(volumeLabel)

        window.alphaValue = 0
    }

    // Limites de volume en dB (peuvent être mises à jour)
    private var limitMinDb: Double = -80.0
    private var limitMaxDb: Double = -21.0

    func updateLimits(minDb: Double, maxDb: Double) {
        self.limitMinDb = minDb
        self.limitMaxDb = maxDb
    }

    func show(volumeDb: Double) {
        guard let window = window, let layer = containerView?.layer else { return }

        hideTimer?.invalidate()

        if isVisible {
            updateVolume(volumeDb)
            scheduleHide()
            return
        }

        // Set fill bar to correct value BEFORE showing (no animation)
        // to avoid flashing the stale value from the previous session
        updateVolume(volumeDb, animated: false)

        isVisible = true
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

        // --- Mise à jour du texte avec Space Mono (affichage en dB) ---
        let volumeText = "\(Int(round(volumeDb))) dB"
        let spaceMonoFont = getSpaceMonoFont(size: 16)

        let attributedString = NSMutableAttributedString(string: volumeText)
        attributedString.addAttribute(.font, value: spaceMonoFont, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: NSRange(location: 0, length: attributedString.length))
        attributedString.addAttribute(.kern, value: -0.32, range: NSRange(location: 0, length: attributedString.length))
        volumeLabel.attributedStringValue = attributedString

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
        hideTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
            self?.hide()
        }
    }

    private func hide() {
        guard let window = window else { return }

        hideTimer?.invalidate()
        hideTimer = nil
        isVisible = false

        // Slide up + fade out with easeInCubic (200ms) via layer transform
        startAnimation(from: 0, to: slideOffset, duration: 0.3, easing: Self.easeInCubic, animateOpacity: (from: 1, to: 0)) { [weak self] in
            guard let self = self, !self.isVisible else { return }
            window.orderOut(nil)
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            self.containerView?.layer?.transform = CATransform3DIdentity
            CATransaction.commit()
        }
    }

    // MARK: - Animation curves

    private static let springCurveValues: [CGFloat] = [
        0, 0.0121, 0.0454, 0.0961, 0.1602, 0.2342, 0.3149, 0.3993, 0.4848, 0.5694, 0.6511, 0.7285, 0.8004, 0.866, 0.9247, 0.9761, 1.0203, 1.0572, 1.0871, 1.1105, 1.1276, 1.1391, 1.1456, 1.1477, 1.146, 1.1412, 1.1337, 1.1243, 1.1134, 1.1015, 1.089, 1.0764, 1.0639, 1.0518, 1.0404, 1.0297, 1.02, 1.0113, 1.0037, 0.9971, 0.9917, 0.9872, 0.9838, 0.9812, 0.9795, 0.9785, 0.9782, 0.9784, 0.9791, 0.9802, 0.9816, 0.9832, 0.985, 0.9868, 0.9887, 0.9905, 0.9923, 0.994, 0.9956, 0.997, 0.9983, 0.9994, 1.0004, 1.0012, 1.0019, 1.0024, 1.0028, 1.003, 1.0032, 1.0032, 1.0032, 1.0031, 1.0029, 1.0027, 1.0025, 1.0022, 1.002, 1.0017, 1.0014, 1.0011, 1.0009, 1.0007, 1.0004, 1.0003, 1.0001, 0.9999, 0.9998, 0.9997, 0.9996, 0.9996, 0.9996, 0.9995, 0.9995, 0.9995, 0.9995, 0.9996, 0.9996, 0.9996, 0.9997, 0.9997, 1
    ]

    private static func springEasing(_ t: CGFloat) -> CGFloat {
        let maxIndex = CGFloat(springCurveValues.count - 1)
        let scaledIndex = t * maxIndex
        let lower = max(0, Int(floor(scaledIndex)))
        let upper = min(lower + 1, springCurveValues.count - 1)
        let fraction = scaledIndex - CGFloat(lower)
        return springCurveValues[lower] + (springCurveValues[upper] - springCurveValues[lower]) * fraction
    }

    private static func easeInCubic(_ t: CGFloat) -> CGFloat {
        t * t * t
    }

    // Animates containerView via CALayer.transform for sub-pixel smooth positioning.
    // No snap threshold needed — Core Animation handles fractional pixels natively,
    // unlike NSWindow.setFrame which rounds to integer pixels.
    private func startAnimation(from: CGFloat, to: CGFloat, duration: CFTimeInterval, easing: @escaping (CGFloat) -> CGFloat, animateOpacity: (from: CGFloat, to: CGFloat)? = nil, completion: (() -> Void)? = nil) {
        animationTimer?.invalidate()
        let startTime = CACurrentMediaTime()

        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] timer in
            guard let self = self, let window = self.window, let layer = self.containerView?.layer else {
                timer.invalidate()
                return
            }

            let elapsed = CACurrentMediaTime() - startTime
            let progress = min(CGFloat(elapsed / duration), 1.0)
            let easedProgress = easing(progress)

            self.currentOffset = from + (to - from) * easedProgress

            // Sub-pixel smooth positioning via Core Animation layer transform
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeTranslation(0, self.currentOffset, 0)
            CATransaction.commit()

            // Drive opacity from the same easing curve.
            // Clamp to [0, 1] since the spring curve overshoots beyond 1.0.
            if let opacity = animateOpacity {
                let rawAlpha = opacity.from + (opacity.to - opacity.from) * easedProgress
                window.alphaValue = min(1.0, max(0.0, rawAlpha))
            }

            if progress >= 1.0 {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DMakeTranslation(0, to, 0)
                CATransaction.commit()
                if let opacity = animateOpacity {
                    window.alphaValue = min(1.0, max(0.0, opacity.to))
                }
                timer.invalidate()
                self.animationTimer = nil
                completion?()
            }
        }
    }

    deinit {
        if let clickMonitor = clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
        }
        hideTimer?.invalidate()
        animationTimer?.invalidate()
        window?.orderOut(nil)
    }
}
