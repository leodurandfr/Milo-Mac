import AppKit

// MARK: - Menu Item Configuration
struct MenuItemConfig {
    let title: String
    let iconName: String
    let isActive: Bool
    let target: AnyObject
    let action: Selector
    let representedObject: Any?
}

// MARK: - Circular Menu Item Component
class CircularMenuItem {
    // MARK: - Constants (dimensions originales)
    private static let iconSize: CGFloat = 26
    private static let circleSize: CGFloat = 26
    private static let circleMargin: CGFloat = 3
    private static let containerWidth: CGFloat = 300
    private static let containerHeight: CGFloat = 32
    private static let textLeftMargin: CGFloat = 46
    private static let textWidth: CGFloat = 140
    private static let textHeight: CGFloat = 16
    private static let textTopMargin: CGFloat = 8
    private static let circleLeftMargin: CGFloat = 14
    
    // MARK: - Gestion globale des spinners
    private static var activeSpinners: [LoadingSpinner] = []
    
    // MARK: - Public Interface
    static func create(with config: MenuItemConfig) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = config.target
        item.action = config.action
        item.representedObject = config.representedObject
        
        let containerView = createContainerView(config: config, menuItem: item)
        item.view = containerView
        
        return item
    }
    
    // MARK: - Public Interface avec support loading
    static func createWithLoadingSupport(with config: MenuItemConfig, isLoading: Bool = false, loadingIsActive: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = config.target
        item.action = config.action
        item.representedObject = config.representedObject

        let containerView = createContainerViewWithLoading(config: config, menuItem: item, isLoading: isLoading, loadingIsActive: loadingIsActive)
        item.view = containerView

        return item
    }

    // MARK: - Nettoyage global des spinners
    static func cleanupAllSpinners() {
        for spinner in activeSpinners {
            spinner.stopAnimating()
        }
        activeSpinners.removeAll()
    }

    // MARK: - Private Methods
    private static func createContainerView(config: MenuItemConfig, menuItem: NSMenuItem) -> NSView {
        return createContainerViewWithLoading(config: config, menuItem: menuItem, isLoading: false, loadingIsActive: false)
    }

    private static func createContainerViewWithLoading(config: MenuItemConfig, menuItem: NSMenuItem, isLoading: Bool, loadingIsActive: Bool = false) -> NSView {
        let containerView = HoverableView(frame: NSRect(
            x: 0,
            y: 0,
            width: containerWidth,
            height: containerHeight
        ))

        let target = config.target
        let action = config.action

        containerView.clickHandler = { [weak target] in
            _ = target?.perform(action, with: menuItem)
        }

        containerView.configureHoverBackground(leftMargin: 5, rightMargin: 5)

        // Créer le cercle avec loader ou icône
        let circleView = createCircleViewWithLoading(config: config, isLoading: isLoading, loadingIsActive: loadingIsActive)
        containerView.addSubview(circleView)

        // Ajouter le texte
        let textField = createTextField(config: config)
        containerView.addSubview(textField)

        return containerView
    }
    
    private static func createCircleView(config: MenuItemConfig) -> NSView {
        return createCircleViewWithLoading(config: config, isLoading: false, loadingIsActive: false)
    }
    
    private static func createCircleViewWithLoading(config: MenuItemConfig, isLoading: Bool, loadingIsActive: Bool = false) -> NSView {
        let circleView = NSView(frame: NSRect(
            x: circleLeftMargin,
            y: circleMargin,
            width: circleSize,
            height: circleSize
        ))
        
        circleView.wantsLayer = true
        circleView.layer?.cornerRadius = circleSize / 2
        
        if isLoading {
            // État loading : fond bleu si loadingIsActive, sinon gris
            if loadingIsActive {
                // Fond bleu comme un élément actif
                if #available(macOS 10.14, *) {
                    circleView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                } else {
                    circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
                }
            } else {
                // Fond gris pour loading inactif
                circleView.layer?.backgroundColor = NSColor.systemGray.cgColor
            }
            
            // Ajouter le spinner blanc et l'enregistrer
            let spinner = LoadingSpinner(frame: NSRect(x: 0, y: 0, width: circleSize, height: circleSize))
            circleView.addSubview(spinner)
            activeSpinners.append(spinner) // AJOUT : Enregistrer le spinner
            spinner.startAnimating()
            
        } else {
            // État normal : couleur selon l'activation + icône
            applyCircleColor(to: circleView, isActive: config.isActive)
            
            let iconView = createIconView(config: config)
            circleView.addSubview(iconView)
        }
        
        return circleView
    }
    
    private static func createIconView(config: MenuItemConfig) -> NSImageView {
        let iconView = NSImageView(frame: NSRect(
            x: 0, // Centrer dans le cercle de 26px
            y: 0,
            width: iconSize, // 26px
            height: iconSize // 26px
        ))
        
        // Récupérer l'icône depuis les Assets
        iconView.image = IconProvider.getIcon(config.iconName)
        
        // Configurer l'icône pour qu'elle s'adapte aux couleurs
        iconView.contentTintColor = config.isActive ? NSColor.white : NSColor.secondaryLabelColor
        
        return iconView
    }
    
    private static func createTextField(config: MenuItemConfig) -> NSTextField {
        let textField = NSTextField(labelWithString: config.title)
        textField.font = NSFont.menuFont(ofSize: 13)
        textField.textColor = NSColor.labelColor
        textField.frame = NSRect(
            x: textLeftMargin,
            y: textTopMargin,
            width: textWidth,
            height: textHeight
        )
        textField.isEditable = false
        textField.isBordered = false
        textField.backgroundColor = NSColor.clear
        
        return textField
    }
    
    private static func applyCircleColor(to circleView: NSView, isActive: Bool) {
        if isActive {
            if #available(macOS 10.14, *) {
                circleView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
            } else {
                circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
            }
        } else {
            circleView.layer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        }
    }
    
    // MARK: - Méthode pour mettre à jour un item existant avec loading
    static func updateItemLoadingState(_ item: NSMenuItem, isLoading: Bool, config: MenuItemConfig, loadingIsActive: Bool = false) {
        guard let containerView = item.view as? HoverableView,
              let circleView = containerView.subviews.first(where: { $0.frame.minX == circleLeftMargin }) else {
            return
        }
        
        // CORRECTION : Toujours nettoyer TOUS les spinners existants d'abord
        for subview in circleView.subviews {
            if let spinner = subview as? LoadingSpinner {
                print("🧹 Nettoyage spinner existant")
                spinner.stopAnimating()
                // Retirer de la liste globale
                if let index = activeSpinners.firstIndex(of: spinner) {
                    activeSpinners.remove(at: index)
                }
                spinner.removeFromSuperview()
            } else {
                // Supprimer les autres subviews (icônes, etc.)
                subview.removeFromSuperview()
            }
        }
        
        if isLoading {
            print("🎬 Création d'un nouveau spinner pour loading")
            
            // Définir la couleur de fond selon l'état
            if loadingIsActive {
                // Fond bleu comme un élément actif
                if #available(macOS 10.14, *) {
                    circleView.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
                } else {
                    circleView.layer?.backgroundColor = NSColor.systemBlue.cgColor
                }
            } else {
                // Fond gris pour loading inactif
                circleView.layer?.backgroundColor = NSColor.systemGray.cgColor
            }
            
            // Créer et ajouter le nouveau spinner
            let spinner = LoadingSpinner(frame: NSRect(x: 0, y: 0, width: circleSize, height: circleSize))
            circleView.addSubview(spinner)
            activeSpinners.append(spinner) // AJOUT : Enregistrer le spinner
            spinner.startAnimating()
            
        } else {
            print("🛑 Arrêt du loading, retour à l'icône normale")
            
            // Retour à l'état normal
            applyCircleColor(to: circleView, isActive: config.isActive)
            
            // Ajouter l'icône normale
            let iconView = createIconView(config: config)
            circleView.addSubview(iconView)
        }
    }
}

// MARK: - Icon Provider simplifié
class IconProvider {
    private static var iconCache: [String: NSImage] = [:]
    
    static func getIcon(_ iconName: String) -> NSImage {
        if let cached = iconCache[iconName] {
            return cached
        }
        
        // Mapper les noms d'icônes vers les noms des assets
        let assetName = mapIconNameToAsset(iconName)
        
        // Charger l'icône depuis les Assets
        if let icon = NSImage(named: assetName) {
            // Configurer comme template pour adaptation automatique des couleurs
            icon.isTemplate = true
            iconCache[iconName] = icon
            return icon
        }
        
        // Fallback vers l'ancien système si l'asset n'existe pas
        let fallbackIcon = createFallbackIcon(iconName)
        iconCache[iconName] = fallbackIcon
        return fallbackIcon
    }
    
    private static func mapIconNameToAsset(_ iconName: String) -> String {
        switch iconName {
        case "music.note":
            return "spotify-icon"
        case "bluetooth":
            return "bluetooth-icon"
        case "desktopcomputer":
            return "macos-icon"
        case "radio":
            return "radio-icon"
        case "podcasts-icon":
            return "podcasts-icon"
        case "speaker.wave.3":
            return "multiroom-icon"
        case "slider.horizontal.3":
            return "equalizer-icon"
        default:
            return iconName
        }
    }
    
    private static func createFallbackIcon(_ iconName: String) -> NSImage {
        let size = CGSize(width: 26, height: 26)
        let image = NSImage(size: size)
        
        image.lockFocus()
        NSColor.labelColor.set()
        
        switch iconName {
        case "music.note":
            let path = NSBezierPath(ovalIn: NSRect(x: 6, y: 2, width: 4, height: 4))
            path.fill()
            let line = NSBezierPath()
            line.move(to: NSPoint(x: 10, y: 6))
            line.line(to: NSPoint(x: 10, y: 12))
            line.lineWidth = 1.5
            line.stroke()
            
        case "bluetooth":
            let path = NSBezierPath()
            path.move(to: NSPoint(x: 9, y: 4))
            path.line(to: NSPoint(x: 9, y: 22))
            path.line(to: NSPoint(x: 17, y: 16))
            path.line(to: NSPoint(x: 13, y: 13))
            path.line(to: NSPoint(x: 17, y: 10))
            path.line(to: NSPoint(x: 9, y: 4))
            path.lineWidth = 2
            path.stroke()
            
        case "desktopcomputer":
            let screen = NSBezierPath(rect: NSRect(x: 4, y: 8, width: 18, height: 12))
            screen.fill()
            let base = NSBezierPath(rect: NSRect(x: 10, y: 6, width: 6, height: 3))
            base.fill()
            
        case "speaker.wave.3":
            let speaker = NSBezierPath(rect: NSRect(x: 4, y: 10, width: 4, height: 6))
            speaker.fill()
            for i in 0..<3 {
                let wave = NSBezierPath()
                wave.move(to: NSPoint(x: 9 + i * 3, y: 10))
                wave.curve(to: NSPoint(x: 9 + i * 3, y: 16),
                          controlPoint1: NSPoint(x: 12 + i * 3, y: 10),
                          controlPoint2: NSPoint(x: 12 + i * 3, y: 16))
                wave.lineWidth = 1.5
                wave.stroke()
            }
            
        case "slider.horizontal.3":
            for i in 0..<3 {
                let bar = NSBezierPath(rect: NSRect(x: 6 + i * 5, y: 6 + i * 2, width: 3, height: 14 - i * 4))
                bar.fill()
            }
            
        default:
            let path = NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 14, height: 14))
            path.fill()
        }
        
        image.unlockFocus()
        image.isTemplate = true
        return image
    }
}

// MARK: - Hoverable View
class HoverableView: NSView {
    var clickHandler: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var hoverBackgroundLayer: CALayer?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }
    
    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }
    
    private func setupView() {
        wantsLayer = true
        setupTrackingArea()
    }
    
    func configureHoverBackground(leftMargin: CGFloat, rightMargin: CGFloat) {
        hoverBackgroundLayer = CALayer()
        hoverBackgroundLayer?.frame = NSRect(
            x: leftMargin,
            y: 0,
            width: bounds.width - leftMargin - rightMargin,
            height: bounds.height
        )
        hoverBackgroundLayer?.cornerRadius = 6
        hoverBackgroundLayer?.backgroundColor = NSColor.clear.cgColor
        
        layer?.insertSublayer(hoverBackgroundLayer!, at: 0)
    }
    
    private func setupTrackingArea() {
        let options: NSTrackingArea.Options = [
            .mouseEnteredAndExited,
            .activeAlways,
            .inVisibleRect
        ]
        
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: options,
            owner: self,
            userInfo: nil
        )
        
        addTrackingArea(trackingArea!)
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        
        if let trackingArea = trackingArea {
            removeTrackingArea(trackingArea)
        }
        
        setupTrackingArea()
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }
    
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        
        let hoverColor: NSColor
        if #available(macOS 10.14, *) {
            hoverColor = NSColor.tertiaryLabelColor
        } else {
            hoverColor = NSColor.lightGray.withAlphaComponent(0.2)
        }
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBackgroundLayer?.backgroundColor = hoverColor.cgColor
        CATransaction.commit()
    }
    
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBackgroundLayer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }
    
    override func mouseDown(with event: NSEvent) {
        clickHandler?()
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }
}

// MARK: - Clickable View
class ClickableView: NSView {
    var clickHandler: (() -> Void)?
    
    override func mouseDown(with event: NSEvent) {
        clickHandler?()
    }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }
}
