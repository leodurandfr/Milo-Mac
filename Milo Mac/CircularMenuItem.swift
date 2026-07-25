import AppKit

// MARK: - Menu Item Configuration
struct MenuItemConfig {
    let title: String
    let iconName: String
    let isActive: Bool
    let target: AnyObject
    let action: Selector
    let representedObject: Any?
    /// Action déclenchée par un appui maintenu (500 ms). Quand elle est nil —
    /// le cas de toutes les lignes sauf la source active — le clic reste
    /// instantané au mouseDown.
    var longPressAction: Selector? = nil
}

// MARK: - Menu Row Metrics

/// Colonnes et centres d'une ligne de menu, **source unique** pour toutes les
/// lignes qui doivent s'aligner entre elles : les lignes de source et de
/// fonctionnalité (`CircularMenuItem`) et les lignes zones/enceintes du
/// multiroom (`MultiroomSection`). Redupliquer ces valeurs les ferait dériver au
/// premier ajustement.
enum MenuRowMetrics {
    static let containerWidth: CGFloat = 300
    static let containerHeight: CGFloat = 32

    /// Pastille ronde d'une ligne de source / fonctionnalité.
    static let circleSize: CGFloat = 26
    static let circleLeftMargin: CGFloat = 14

    /// Colonne de texte : c'est sur elle que s'alignent les noms de zones et
    /// d'enceintes.
    static let textLeftMargin: CGFloat = 46
    static let textHeight: CGFloat = 16

    /// Marge droite, alignée sur `MenuItemFactory.rightMargin`.
    static let rightMargin: CGFloat = 14

    /// Centre horizontal de la pastille — les icônes du multiroom (caret de zone,
    /// haut-parleur d'enceinte) se centrent dessus pour tomber dans le même axe.
    static var circleCenterX: CGFloat { circleLeftMargin + circleSize / 2 }

    /// Pastille et texte sont centrés verticalement dans la ligne.
    static var circleMargin: CGFloat { (containerHeight - circleSize) / 2 }
    static var textTopMargin: CGFloat { (containerHeight - textHeight) / 2 }
}

// MARK: - Circular Menu Item Component
class CircularMenuItem {
    // MARK: - Constants (dimensions originales)
    private static let iconSize: CGFloat = 26
    private static let circleSize = MenuRowMetrics.circleSize
    private static let circleMargin = MenuRowMetrics.circleMargin
    private static let containerWidth = MenuRowMetrics.containerWidth
    private static let containerHeight = MenuRowMetrics.containerHeight
    private static let textLeftMargin = MenuRowMetrics.textLeftMargin
    private static let textWidth: CGFloat = 140
    private static let textHeight = MenuRowMetrics.textHeight
    private static let textTopMargin = MenuRowMetrics.textTopMargin
    private static let circleLeftMargin = MenuRowMetrics.circleLeftMargin

    // MARK: - Gestion globale des spinners
    private static var activeSpinners: [LoadingSpinner] = []

    // MARK: - Public Interface
    static func createWithLoadingSupport(with config: MenuItemConfig, isLoading: Bool = false, loadingIsActive: Bool = false) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = config.target
        item.action = config.action
        item.representedObject = config.representedObject

        let containerView = createContainerView(config: config, menuItem: item, isLoading: isLoading, loadingIsActive: loadingIsActive)
        item.view = containerView

        return item
    }

    // MARK: - Nettoyage global des spinners
    static func cleanupAllSpinners() {
        for spinner in activeSpinners {
            spinner.stopAnimating()
            spinner.removeFromSuperview()
        }
        activeSpinners.removeAll()
    }

    /// Register an externally-created spinner so it gets stopped by
    /// cleanupAllSpinners on the next menu rebuild, matching the lifecycle of
    /// spinners created internally by createCircleView.
    static func registerSpinner(_ spinner: LoadingSpinner) {
        activeSpinners.append(spinner)
    }

    // MARK: - Private Methods
    private static func createContainerView(config: MenuItemConfig, menuItem: NSMenuItem, isLoading: Bool, loadingIsActive: Bool) -> NSView {
        let containerView = HoverableView(frame: NSRect(
            x: 0,
            y: 0,
            width: containerWidth,
            height: containerHeight
        ))

        let target = config.target
        let action = config.action

        // menuItem capturé weak : NSMenuItem retient la vue (item.view), la vue
        // retient la closure — une capture forte formerait un cycle qui ferait
        // fuiter chaque ligne du menu à chaque rebuild. L'item est forcément
        // vivant tant que sa vue est cliquable (le NSMenu le retient).
        containerView.clickHandler = { [weak target, weak menuItem] in
            guard let menuItem else { return }
            _ = target?.perform(action, with: menuItem)
        }

        if let longPressAction = config.longPressAction {
            containerView.longPressHandler = { [weak target, weak menuItem] in
                guard let menuItem else { return }
                _ = target?.perform(longPressAction, with: menuItem)
            }
        }

        containerView.configureHoverBackground(leftMargin: 5, rightMargin: 5)

        // Créer le cercle avec loader ou icône
        let circleView = createCircleView(config: config, isLoading: isLoading, loadingIsActive: loadingIsActive)
        containerView.addSubview(circleView)

        // Ajouter le texte
        let textField = createTextField(config: config)
        containerView.addSubview(textField)

        // Contenu atténué pendant l'appui maintenu (sans toucher au fond de survol,
        // qui vit dans un CALayer du container et non dans ses sous-vues).
        containerView.pressFadeViews = [circleView, textField]

        return containerView
    }

    private static func createCircleView(config: MenuItemConfig, isLoading: Bool, loadingIsActive: Bool) -> NSView {
        let circleView = NSView(frame: NSRect(
            x: circleLeftMargin,
            y: circleMargin,
            width: circleSize,
            height: circleSize
        ))

        circleView.wantsLayer = true
        circleView.layer?.cornerRadius = circleSize / 2

        if isLoading {
            // État loading : fond accent si loadingIsActive, sinon gris
            circleView.layer?.backgroundColor = loadingIsActive
                ? NSColor.controlAccentColor.cgColor
                : NSColor.systemGray.cgColor

            // Ajouter le spinner blanc et l'enregistrer
            let spinner = LoadingSpinner(frame: NSRect(x: 0, y: 0, width: circleSize, height: circleSize))
            circleView.addSubview(spinner)
            activeSpinners.append(spinner)
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
        iconView.imageScaling = .scaleProportionallyDown
        iconView.imageAlignment = .alignCenter

        // Appliquer une taille adaptée pour les SF Symbols
        if IconProvider.isSFSymbol(config.iconName) {
            iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        }

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
        circleView.layer?.backgroundColor = isActive
            ? NSColor.controlAccentColor.cgColor
            : NSColor.tertiaryLabelColor.cgColor
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

        // Essayer comme SF Symbol natif
        if let sfIcon = NSImage(systemSymbolName: assetName, accessibilityDescription: nil) {
            sfIcon.isTemplate = true
            iconCache[iconName] = sfIcon
            return sfIcon
        }

        // Fallback vers l'ancien système si l'asset n'existe pas
        let fallbackIcon = createFallbackIcon(iconName)
        iconCache[iconName] = fallbackIcon
        return fallbackIcon
    }

    static func isSFSymbol(_ iconName: String) -> Bool {
        let assetName = mapIconNameToAsset(iconName)
        return NSImage(named: assetName) == nil && NSImage(systemSymbolName: assetName, accessibilityDescription: nil) != nil
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
        case "airplayaudio":
            return "airplay.audio"
        case "speaker.wave.3":
            return "multiroom-icon"
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

    /// Action d'appui maintenu. Tant qu'elle est nil, mouseDown déclenche le
    /// clic immédiatement (comportement historique de toutes les lignes).
    var longPressHandler: (() -> Void)?

    /// Sous-vues atténuées pendant l'appui pour signaler la progression du geste.
    var pressFadeViews: [NSView] = []

    /// Début de l'appui long en cours, s'il y en a un. Statique car il ne peut
    /// y avoir qu'un seul appui souris à la fois : MenuBarController s'en sert
    /// pour différer le rebuild du menu, qui détruirait la vue en plein geste.
    private(set) static var activePressStartedAt: Date?

    /// Aligné sur HOLD_DELAY du frontend web (useDockAppHold.js).
    static let longPressDelay: TimeInterval = 0.5
    private static let pressFadeAlpha: CGFloat = 0.35
    /// Nettement plus court que le geste : la ligne accuse le coup tout de suite,
    /// puis reste atténuée jusqu'au déclenchement. Étalé sur les 500 ms, le fondu
    /// se lisait comme une latence plutôt que comme une réponse.
    private static let pressFadeDuration: TimeInterval = 0.15
    private static let pressCancelDuration: TimeInterval = 0.12
    /// Au-delà, on considère que l'utilisateur fait autre chose qu'un appui.
    private static let pressMoveTolerance: CGFloat = 4

    private var trackingArea: NSTrackingArea?
    private var hoverBackgroundLayer: CALayer?
    private var pressTimer: Timer?
    private var pressOrigin: NSPoint?
    private var longPressFired = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupView()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupView()
    }

    deinit {
        pressTimer?.invalidate()
        if pressOrigin != nil {
            HoverableView.activePressStartedAt = nil
        }
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

        // Un rebuild du menu retire la vue de sa fenêtre : ne pas laisser
        // derrière soi un timer d'appui ni un verrou de refresh orphelin.
        if window == nil {
            cancelPress()
        }
    }

    func setHoverActive(_ active: Bool) {
        let color: NSColor = active ? NSColor.tertiaryLabelColor : .clear

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverBackgroundLayer?.backgroundColor = color.cgColor
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        setHoverActive(true)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        setHoverActive(false)
        cancelPress()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        guard longPressHandler != nil else {
            clickHandler?()
            return
        }

        beginPress(at: point)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = pressOrigin else { return }

        let point = convert(event.locationInWindow, from: nil)
        if abs(point.x - origin.x) > HoverableView.pressMoveTolerance
            || abs(point.y - origin.y) > HoverableView.pressMoveTolerance {
            cancelPress()
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard longPressHandler != nil else {
            super.mouseUp(with: event)
            return
        }

        let fired = longPressFired
        cancelPress()

        // Appui long déjà déclenché : on avale le clic de relâchement pour ne
        // pas réenchaîner sur l'action normale.
        if !fired {
            clickHandler?()
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }

    // MARK: - Appui maintenu

    private func beginPress(at point: NSPoint) {
        pressTimer?.invalidate()
        pressOrigin = point
        longPressFired = false
        HoverableView.activePressStartedAt = Date()

        setPressFade(active: true, duration: HoverableView.pressFadeDuration)

        // Mode .common : NSMenu fait tourner sa propre boucle de tracking, un
        // timer en mode .default ne se déclencherait jamais menu ouvert.
        let timer = Timer(timeInterval: HoverableView.longPressDelay, repeats: false) { [weak self] _ in
            guard let self, self.pressOrigin != nil else { return }

            // Filet de sécurité : si le mouseUp n'a pas été délivré (relâchement
            // hors fenêtre pendant le tracking du menu), un clic bref ne doit
            // pas se transformer en appui long.
            guard NSEvent.pressedMouseButtons & 0x1 != 0 else {
                self.cancelPress()
                return
            }

            self.longPressFired = true
            self.longPressHandler?()
        }
        RunLoop.main.add(timer, forMode: .common)
        pressTimer = timer
    }

    private func cancelPress() {
        pressTimer?.invalidate()
        pressTimer = nil

        guard pressOrigin != nil else { return }
        pressOrigin = nil
        HoverableView.activePressStartedAt = nil

        setPressFade(active: false, duration: HoverableView.pressCancelDuration)
    }

    private func setPressFade(active: Bool, duration: TimeInterval) {
        // Core Animation s'exécute côté render server : le fondu progresse
        // normalement malgré la boucle de tracking du menu.
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            for view in pressFadeViews {
                view.animator().alphaValue = active ? HoverableView.pressFadeAlpha : 1.0
            }
        }
    }
}

// MARK: - Radio Station Item View
/// Custom view for radio station submenu items.
/// Using custom views prevents NSMenu from closing on click.
class RadioStationItemView: NSView {
    let stationId: String
    private var clickHandler: (() -> Void)?
    private var trackingArea: NSTrackingArea?
    private var hoverLayer: CALayer?
    private var stopLabel: NSTextField?

    private static let viewWidth: CGFloat = 200
    private static let viewHeight: CGFloat = 22
    private static let horizontalPadding: CGFloat = 12
    private static let cornerRadius: CGFloat = 4

    init(stationId: String, stationName: String, isPlaying: Bool, clickHandler: @escaping () -> Void) {
        self.stationId = stationId
        super.init(frame: NSRect(x: 0, y: 0, width: Self.viewWidth, height: Self.viewHeight))
        self.clickHandler = clickHandler

        wantsLayer = true

        // Hover background (like standard menu item)
        hoverLayer = CALayer()
        hoverLayer?.frame = NSRect(x: 4, y: 0, width: bounds.width - 8, height: bounds.height)
        hoverLayer?.cornerRadius = Self.cornerRadius
        hoverLayer?.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hoverLayer!)

        // Station name (vertically centered)
        let nameLabel = NSTextField(labelWithString: stationName)
        nameLabel.font = NSFont.menuFont(ofSize: 13)
        nameLabel.textColor = NSColor.labelColor
        nameLabel.sizeToFit()
        nameLabel.frame = NSRect(
            x: Self.horizontalPadding,
            y: (Self.viewHeight - nameLabel.frame.height) / 2,
            width: bounds.width - 50,
            height: nameLabel.frame.height
        )
        nameLabel.isEditable = false
        nameLabel.isBordered = false
        nameLabel.backgroundColor = .clear
        nameLabel.lineBreakMode = .byTruncatingTail
        addSubview(nameLabel)

        applyPlayingState(isPlaying)
        setupTrackingArea()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Mutate the view in place — add/remove the ⏹ glyph and swap the click
    /// handler — so the visible submenu flyout refreshes without needing to
    /// be rebuilt or closed.
    func update(isPlaying: Bool, clickHandler: @escaping () -> Void) {
        self.clickHandler = clickHandler
        applyPlayingState(isPlaying)
    }

    private func applyPlayingState(_ isPlaying: Bool) {
        stopLabel?.removeFromSuperview()
        stopLabel = nil

        guard isPlaying else { return }

        let stop = NSTextField(labelWithString: "⏹")
        stop.font = NSFont.systemFont(ofSize: 11)
        stop.textColor = NSColor.secondaryLabelColor
        stop.sizeToFit()
        stop.frame = NSRect(
            x: bounds.width - 28,
            y: (Self.viewHeight - stop.frame.height) / 2,
            width: 16,
            height: stop.frame.height
        )
        stop.isEditable = false
        stop.isBordered = false
        stop.backgroundColor = .clear
        stop.alignment = .right
        addSubview(stop)
        stopLabel = stop
        needsDisplay = true
    }

    private func setupTrackingArea() {
        trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea!)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let ta = trackingArea { removeTrackingArea(ta) }
        setupTrackingArea()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer?.backgroundColor = NSColor.tertiaryLabelColor.cgColor
        CATransaction.commit()
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func mouseDown(with event: NSEvent) {
        // Clear the hover background before the click fires: NSMenu dismisses
        // the flyout on click without calling mouseExited on the reused view,
        // so the highlight would otherwise persist on the next open.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer?.backgroundColor = NSColor.clear.cgColor
        CATransaction.commit()
        clickHandler?()
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        return bounds.contains(point) ? self : nil
    }
}
