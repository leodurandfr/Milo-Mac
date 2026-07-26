import AppKit
import SwiftUI
import Observation

/// Fenêtre du panneau. Sans bordure, elle doit pouvoir devenir fenêtre clé — sinon le
/// slider ne répondrait pas et le matériau se rendrait en état « inactif » (plus clair).
private final class PanelWindow: NSPanel {
    override var canBecomeKey: Bool { true }

    /// Sans ça, le panneau s'ouvre 60 pt trop bas.
    ///
    /// AppKit « recale » d'office toute fenêtre dont le bord haut dépasse le bas de la barre
    /// des menus. Or la nôtre est VOLONTAIREMENT plus haute que le panneau : elle l'entoure
    /// d'une marge transparente de `shadowMargin` (60 pt) pour laisser l'ombre s'étaler. Son
    /// bord haut passe donc au-dessus du haut de l'écran, et AppKit la redescendait d'autant.
    ///
    /// Mesuré, avant correction : bord haut du verre à 94,5 pt, contre 34,5 pt pour « Son » —
    /// soit exactement les 60 pt de la marge. C'est le même symptôme que le piège des
    /// contraintes documenté dans `setupPanel()`, mais une cause toute différente : ici ce
    /// n'est pas la disposition interne, c'est la fenêtre elle-même qu'on déplaçait.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Conteneur transparent qui entoure le verre d'une marge, afin que l'ombre portée ait la
/// place de s'étaler : une couche ne peut pas dessiner d'ombre au-delà des bords de sa
/// fenêtre.
///
/// Ses marges ne doivent pas capter les clics — sans quoi cliquer « à côté » du panneau,
/// dans le vide, ne le refermerait pas.
private final class ShadowContainerView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// Coquille de la barre de menus : un NSStatusItem qui présente le panneau SwiftUI dans une
/// fenêtre sans bordure.
///
/// **Pourquoi pas un NSMenu ?** C'était pourtant la voie naturelle, et on l'a essayée. Mais
/// un NSMenu peint son propre chrome et aucune API publique ne permet de le changer.
/// Mesuré : coins de 14,5 pt et liseré marqué, contre 18 pt et un bord discret pour les
/// modules système (Son, Bluetooth). Impossible d'être iso en restant dans un menu.
///
/// **Pourquoi pas MenuBarExtra ?** Il confisque le NSStatusItem : on perdrait le contrôle de
/// l'icône (l'opacité réduite hors connexion) et l'option-clic. Son style `.menu` rend bien
/// un vrai NSMenu, mais il ignore les images et ne sait pas afficher de slider.
///
/// **Pourquoi pas NSPopover ?** Il dessine toujours une flèche vers son ancre, non masquable.
///
/// Le prix de la fenêtre : la fermeture au clic extérieur, que NSMenu et NSPopover offraient
/// gratuitement, doit être recâblée à la main (voir plus bas).
@MainActor
final class MenuBarShell: NSObject, NSWindowDelegate {
    private let statusItem: NSStatusItem
    private let store: MiloStore

    private let panel: PanelWindow
    private let hostingController: NSHostingController<MiloPanelView>

    /// Le fond du panneau : le verre de macOS 26.
    ///
    /// Et non un `NSVisualEffectView`. Mesuré sur fond uni, l'intérieur du panneau « Son »
    /// vaut 8 sur noir et 83 sur blanc — soit une transmission de 0,294 avec une base très
    /// sombre. Le meilleur matériau legacy (`.toolTip`) donne 36 / 83, et aucun réglage
    /// d'opacité ne permet d'atteindre cette combinaison : assombrir un matériau réduit ses
    /// deux valeurs à la fois. Control Center n'utilise donc pas l'ancien système de
    /// matériaux, mais Liquid Glass.
    ///
    /// ⚠️ Ne PAS tenter le modificateur SwiftUI `.glassEffect()` à la racine de la vue : dans
    /// une NSPanel transparente il rend la fenêtre entièrement invisible, contenu compris
    /// (vérifié : fenêtre visible, alpha 1, mais ne peignant rien). C'est bien la vue AppKit
    /// qu'il faut, avec la vue SwiftUI placée dans son `contentView`.
    private let glassView = NSGlassEffectView()

    /// Surveille les clics hors du panneau pour le refermer.
    private var outsideClickMonitor: Any?

    /// Vrai pendant le fondu de sortie. La fenêtre est encore « visible » à ce moment-là.
    private var isHiding = false

    init(store: MiloStore) {
        self.store = store
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Le plafond de hauteur est réévalué à chaque ouverture (`positionPanel`), l'écran
        // pouvant changer ; celui d'ici n'est qu'une valeur de départ.
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

    /// Le comportement historique, préservé tel quel : l'icône est à moitié transparente
    /// tant que Milō n'est pas joignable.
    private func updateIcon() {
        statusItem.button?.alphaValue = store.isConnected ? 1.0 : 0.5
    }

    /// `@Observable` ne notifie qu'une seule fois par observation : il faut se réarmer à
    /// chaque changement, sinon l'icône ne se met à jour qu'une fois.
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

    // MARK: - Panneau

    private func setupPanel() {
        // Le verre porte le contenu SwiftUI et définit la forme du panneau.
        glassView.contentView = hostingController.view
        glassView.cornerRadius = PanelMetrics.cornerRadius

        // Ombre dessinée à la main. Celle de NSWindow n'est pas réglable et se révèle bien
        // trop serrée : mesurée sur fond blanc, elle porte à 15,5 pt et assombrit de 72 au
        // bord, là où celle de « Son » porte à 48,5 pt en n'assombrissant que de 48 — trois
        // fois plus large et bien plus douce.
        glassView.wantsLayer = true
        glassView.layer?.masksToBounds = false
        glassView.layer?.shadowColor = NSColor.black.cgColor
        glassView.layer?.shadowOpacity = PanelMetrics.shadowOpacity
        glassView.layer?.shadowRadius = PanelMetrics.shadowRadius
        glassView.layer?.shadowOffset = CGSize(width: 0, height: -PanelMetrics.shadowOffsetY)

        // Une couche ne peut pas dessiner d'ombre au-delà des bords de sa fenêtre : le verre
        // est donc encastré dans un conteneur plus grand, dont les marges transparentes
        // laissent l'ombre s'étaler.
        //
        // ⚠️ Par CONTRAINTES, et non en posant `glassView.frame` : NSGlassEffectView gère la
        // disposition de son contentView et écrase le cadre qu'on lui donne. Le verre se
        // retrouvait alors collé en bas du conteneur, toute la marge passait au-dessus, et le
        // panneau s'ouvrait 60 pt trop bas sous la barre des menus.
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
        // Pas de mise à l'échelle : l'apparition et la disparition sont de simples fondus,
        // pilotés à la main dans showPanel/hidePanel.
        panel.animationBehavior = .none
    }

    @objc private func statusItemClicked() {
        // Panneau visible : ce clic est un basculement vers « fermé ». Y compris quand il est
        // DÉJÀ en train de se fermer — car c'est souvent ce même clic qui l'a fermé : sur un
        // vrai clic, le mouse-down lui fait perdre le focus (`windowDidResignKey` → `hidePanel`)
        // AVANT que le mouse-up ne déclenche cette action. On laisse donc la fermeture aller à
        // son terme au lieu de rouvrir (sinon l'icône ne refermait jamais le panneau).
        if panel.isVisible {
            if !isHiding { hidePanel() }
            return
        }

        // Option-clic : le panneau s'ouvre avec son pied (Paramètres, Quitter).
        //
        // On lit l'état VIVANT des modificateurs (`NSEvent.modifierFlags`), et non ceux portés
        // par `NSApp.currentEvent` : sur l'action d'un NSStatusItem, l'event du mouse-up arrive
        // avec des `modifierFlags` vides (vérifié : option enfoncée, `currentEvent` à 0, état
        // global à `.option`). S'appuyer dessus laissait le pied invisible.
        store.showsPreferences = NSEvent.modifierFlags.contains(.option)

        showPanel()
    }

    private func showPanel() {
        // Le HUD du raccourci clavier flotte au-dessus de tout : le masquer pour qu'il ne
        // recouvre pas le panneau qu'on vient d'ouvrir.
        store.hotkeyManager?.volumeHUD?.hide()

        store.isPanelOpen = true
        store.refreshPanelData()

        positionPanel()

        // L'app est en policy .accessory : elle n'est pas active quand on clique dans la
        // barre des menus, donc la fenêtre s'ouvrirait **non-clé** et son matériau se
        // rendrait en état « inactif » (visiblement plus clair). Activer AVANT le show ne
        // suffit pas — l'activation n'a pas encore pris effet quand la fenêtre est créée.
        isHiding = false
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKey()

        // Comme « Son » : l'apparition est vive, la disparition plus lente.
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
            // La closure de fin n'est pas isolée sur le main actor : on y revient
            // explicitement plutôt que d'y toucher `isHiding` directement.
            Task { @MainActor in
                guard let self, self.isHiding else { return }
                self.panel.orderOut(nil)
                self.isHiding = false
            }
        })
    }

    /// Marge transparente à gauche de l'encre, DANS l'image de l'icône. Mesurée une fois
    /// plutôt que codée en dur : si l'asset change, l'alignement du panneau suit.
    private var cachedIconInkInset: CGFloat?

    /// Abscisse du premier pixel VISIBLE de l'icône, dans le repère de l'écran.
    ///
    /// Le bouton d'un NSStatusItem centre son image, et l'image elle-même a du vide autour
    /// de son dessin. Les deux s'additionnent : notre bouton fait 40 pt, l'image 22, l'encre
    /// 14 — l'encre commence donc à 13 pt du bord du bouton. Celui de « Son » est ajusté à
    /// son glyphe (encre à 1,5 pt du bord). S'ancrer sur le CADRE du bouton, comme le fait le
    /// système, nous décalerait de 11,5 pt : on s'ancre donc sur l'encre.
    private func iconInkMinX(button: NSStatusBarButton, buttonRect: NSRect) -> CGFloat {
        guard let image = button.image else { return buttonRect.minX }

        let inkInset: CGFloat
        if let cachedIconInkInset {
            inkInset = cachedIconInkInset
        } else {
            inkInset = Self.leftInkInset(of: image)
            cachedIconInkInset = inkInset
        }

        // L'image est centrée dans le bouton.
        let imageMinX = buttonRect.minX + (buttonRect.width - image.size.width) / 2
        return imageMinX + inkInset
    }

    /// Première colonne non transparente de l'image.
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

    /// Place le panneau sous l'icône, aligné à gauche sur elle, sans déborder de l'écran.
    private func positionPanel() {
        guard let button = statusItem.button,
              let buttonWindow = button.window,
              let screen = buttonWindow.screen ?? NSScreen.main else { return }

        // Ce que l'écran peut afficher. Le contenu s'y plafonne lui-même (la liste des stations
        // défile au-delà) : il faut donc le lui dire AVANT de le mesurer. On ne réécrit la vue
        // que si la valeur a bougé — sinon on invaliderait la disposition à chaque ouverture.
        let maxContentHeight = PanelMetrics.maxContentHeight(on: screen)
        if hostingController.rootView.maxContentHeight != maxContentHeight {
            hostingController.rootView.maxContentHeight = maxContentHeight
        }

        // La taille vient du contenu SwiftUI : elle change selon que le pied est visible,
        // que Milō est connecté, ou qu'on est dans la liste des stations radio.
        hostingController.view.layoutSubtreeIfNeeded()
        var size = hostingController.view.fittingSize

        // Hauteur ENTIÈRE, indispensable au calage sous-pixel : voir `shadowMargin`, dont les
        // 60,5 pt ne tombent juste que si la hauteur du contenu est entière.
        //
        // Sans ce calage, le panneau glissait d'un pixel selon la parité du contenu — vérifié :
        // à 420,5 pt de contenu il s'ouvrait à 34,5, à 416,0 il tombait à 35,0. Or le contenu
        // change tout le temps (connexion, pied, liste radio).
        //
        // Le plafond est appliqué APRÈS l'arrondi, et il est lui-même entier : la hauteur reste
        // donc entière dans les deux cas. (Dans l'autre ordre, l'arrondi vers le haut pourrait
        // faire repasser la hauteur au-dessus du plafond.) C'est une ceinture-bretelle : le
        // contenu se borne déjà tout seul, `fittingSize` ne devrait jamais dépasser.
        size.height = min(size.height.rounded(.up), maxContentHeight)

        hostingController.view.frame = NSRect(origin: .zero, size: size)

        // La fenêtre est plus grande que le panneau : la marge accueille l'ombre. Le verre y
        // est centré par les contraintes posées dans setupPanel().
        let m = PanelMetrics.shadowMargin
        panel.setContentSize(NSSize(width: size.width + 2 * m, height: size.height + 2 * m))

        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))

        // On positionne le PANNEAU, puis on décale la fenêtre de la marge.
        //
        // Aligné à GAUCHE sur l'icône, et non centré dessous : c'est ce que font les modules
        // système. Mesuré sur « Son » : son panneau commence 11,5 pt à gauche de l'encre de
        // son glyphe — ses pastilles (à 14 pt du bord) tombent alors 2,5 pt à droite de
        // l'encre, l'alignement optique que l'œil lit comme « aligné ».
        var x = iconInkMinX(button: button, buttonRect: buttonRect) - PanelMetrics.panelLeftFromIconInk
        let visible = screen.visibleFrame
        x = min(max(x, visible.minX + PanelMetrics.screenEdgeMargin),
                visible.maxX - size.width - PanelMetrics.screenEdgeMargin)

        // Ancré sur le bas de la BARRE DES MENUS (`visibleFrame.maxY`), et non sur le bas du
        // bouton : sur un écran à encoche la barre est plus haute que l'élément d'état, et
        // s'ancrer au bouton fait chevaucher le panneau sous la barre.
        let y = visible.maxY - PanelMetrics.topGap - size.height

        panel.setFrameOrigin(NSPoint(x: x - m, y: y - m))
    }

    // MARK: - Fermeture au clic extérieur

    /// `NSMenu` et `NSPopover.behavior = .transient` faisaient ça tout seuls. Avec une
    /// fenêtre, il faut surveiller soi-même les clics ailleurs — y compris dans les autres
    /// applications, d'où le moniteur **global**.
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

    /// Le panneau perd le focus (Cmd-Tab, autre app, ouverture des Réglages) : on le ferme,
    /// comme le font Son et Bluetooth.
    func windowDidResignKey(_ notification: Notification) {
        guard panel.isVisible else { return }
        hidePanel()
    }
}
