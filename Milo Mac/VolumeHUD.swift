import AppKit
import Foundation
import CoreText

class VolumeHUD {
    private var window: NSWindow?
    private var containerView: NSVisualEffectView?
    private var fillView: NSView?
    private var volumeLabel: NSTextField?
    private var hideTimer: Timer?
    
    private let windowWidth: CGFloat = 472
    private let windowHeight: CGFloat = 64
    private let sliderHeight: CGFloat = 32
    private let cornerRadius: CGFloat = 32
    
    init() {
        setupWindow()
        setupViews()
    }
    
    // Fonction pour obtenir la police Space Mono
    private func getSpaceMonoFont(size: CGFloat) -> NSFont {
        // Nom exact de la police (trouvé dans les informations du fichier)
        if let font = NSFont(name: "Space Mono Regular", size: size) {
            // print("✅ Space Mono trouvée avec le nom: Space Mono Regular")
            return font
        }
        
        print("⚠️ Space Mono non trouvée, utilisation de la police système monospace")
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }
    
    private func setupWindow() {
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        
        guard let window = window else { return }
        
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.maximumWindow)) + 1)
        window.backgroundColor = NSColor.clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .stationary]
        
        if let screen = NSScreen.main {
            let screenRect = screen.visibleFrame
            let windowRect = NSRect(
                x: screenRect.midX - windowWidth / 2,
                y: screenRect.maxY - windowHeight - 20,
                width: windowWidth,
                height: windowHeight
            )
            window.setFrame(windowRect, display: false)
        }
        
        window.alphaValue = 0
    }
    
    private func setupViews() {
        guard let window = window else { return }
        
        containerView = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: windowWidth, height: windowHeight))
        guard let containerView = containerView else { return }
        
        containerView.material = .hudWindow
        containerView.blendingMode = .behindWindow
        containerView.state = .active
        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = cornerRadius
        containerView.layer?.borderWidth = 2
        containerView.layer?.borderColor = NSColor(white: 1.0, alpha: 0.1).cgColor
        
        window.contentView = containerView
        
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
        volumeLabel = NSTextField(labelWithString: "-30 dB")
        guard let volumeLabel = volumeLabel else { return }

        let spaceMonoFont = getSpaceMonoFont(size: 16)
        volumeLabel.font = spaceMonoFont

        let attributedString = NSMutableAttributedString(string: "-30 dB")
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
        guard let window = window else { return }

        updateVolume(volumeDb)
        hideTimer?.invalidate()
        window.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 1.0
        }

        scheduleHide()
    }

    private func updateVolume(_ volumeDb: Double) {
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

        // --- Animation fluide ---
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)

            fillView.animator().frame = NSRect(
                x: fillX,
                y: 0,
                width: fillWidth,
                height: sliderHeight
            )
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
        
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().alphaValue = 0.0
        }) {
            window.orderOut(nil)
        }
    }
    
    deinit {
        hideTimer?.invalidate()
        window?.orderOut(nil)
    }
}
