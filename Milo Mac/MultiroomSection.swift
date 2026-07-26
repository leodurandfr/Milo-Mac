import AppKit

// MARK: - Géométrie

/// Les lignes s'insèrent dans le menu principal, sous « Multiroom » : elles font
/// donc exactement la largeur des autres lignes (300 px). `NSMenu` se dimensionne
/// sur sa vue la plus large — une ligne plus large décalerait tout le reste.
private enum MultiroomLayout {
    static let rowWidth = MenuRowMetrics.containerWidth
    /// Exactement la hauteur de l'en-tête « Multiroom » : le sous-niveau prolonge
    /// la section, il ne pèse pas plus lourd que sa tête.
    static let rowHeight = MenuItemFactory.featureRowHeight

    /// Boîte du glyphe (caret de zone, haut-parleur d'enceinte), calée sur le bord
    /// gauche du titre « Multiroom » — donc décalée d'un caret vers la droite par
    /// rapport à l'en-tête. Ce micro-décalage est ce qui fait lire le bloc comme un
    /// sous-niveau, sans l'indentation franche qui l'éloignerait de sa section.
    ///
    /// Le glyphe est centré dans sa boîte plutôt que collé à gauche : leurs
    /// largeurs vont du chevron étroit au `hifispeaker.2.fill`, un calage à gauche
    /// donnerait une colonne en dents de scie.
    static let iconSize: CGFloat = 15
    static let iconX = MenuItemFactory.sideMargin + MenuItemFactory.caretSlot

    static let nameX = iconX + iconSize + 4

    static let nameFont = NSFont.menuFont(ofSize: 13)

    static let muteSize: CGFloat = 20
    static let muteX = rowWidth - MenuRowMetrics.rightMargin - muteSize
    static let sliderEnd = muteX - 10
    /// La piste du slider est dessinée sur 22 px fixes, centrée sur `midY` : plus
    /// bas, elle déborderait de sa vue au lieu de rétrécir.
    static let sliderHeight: CGFloat = 22

    /// Zones et enceintes partagent le même bord gauche (pas d'indentation des
    /// membres) : la zone se reconnaît à son chevron, l'enceinte à son icône de
    /// haut-parleur. Tous les sliders démarrent ainsi sur la même colonne.
    ///
    /// Le plafond de largeur des noms garantit qu'il reste ~90 px de slider dans
    /// le pire cas. À 300 px, il n'y a pas la place d'afficher en plus la valeur
    /// en dB que montre le frontend web.
    static let minNameWidth: CGFloat = 70
    static let maxNameWidth: CGFloat = 110

    static func sliderOrigin(nameWidth: CGFloat) -> CGFloat {
        nameX + nameWidth + 10
    }

    /// Durée d'interpolation d'une ligne mise à jour depuis le serveur, calée sur
    /// la cadence des échos d'un drag (throttle zone 80 ms).
    static let volumeGlideDuration: TimeInterval = 0.1
}

// MARK: - Sous-vues non cliquables

/// Libellés et icônes ne doivent pas intercepter la souris : seuls le slider et
/// le bouton mute ont leur propre zone active, le reste de la ligne appartient à
/// la ligne (dépliage d'une zone).
private final class PassthroughTextField: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class PassthroughImageView: NSImageView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Bouton mute

/// Bouton maison plutôt qu'un `NSButton` : dans un `NSMenu`, une vue qui traite
/// elle-même `mouseDown` garantit que le menu ne se referme pas — même raison
/// que `CircularMenuItem` / `RadioStationItemView`.
private final class MultiroomMuteButton: NSView {
    var onClick: (() -> Void)?

    private let imageView = PassthroughImageView()
    private var trackingArea: NSTrackingArea?
    private var hoverLayer: CALayer?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: MultiroomLayout.muteSize, height: MultiroomLayout.muteSize))
        wantsLayer = true

        let hover = CALayer()
        hover.frame = bounds
        hover.cornerRadius = MultiroomLayout.muteSize / 2
        hover.backgroundColor = NSColor.clear.cgColor
        layer?.addSublayer(hover)
        hoverLayer = hover

        imageView.frame = bounds
        imageView.imageScaling = .scaleProportionallyDown
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(muted: Bool) {
        let symbol = muted ? "speaker.slash.fill" : "speaker.wave.2.fill"
        imageView.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        imageView.contentTintColor = muted ? NSColor.tertiaryLabelColor : NSColor.labelColor
        setAccessibilityLabel(muted ? L("multiroom.unmute") : L("multiroom.mute"))
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func setHover(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer?.backgroundColor = active ? NSColor.tertiaryLabelColor.cgColor : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    override func mouseDown(with event: NSEvent) {
        setHover(false)
        onClick?()
    }
}

// MARK: - Ligne

/// Ce qu'affiche une ligne à droite du nom.
enum MultiroomRowControl {
    case slider(volumeDb: Double, minDb: Double, maxDb: Double)
    /// Pastille informative : hors ligne, ou volume géré par un ampli externe.
    case pill(String)
}

struct MultiroomRowModel {
    let iconSymbol: String
    let name: String
    let control: MultiroomRowControl
    let muted: Bool
    let showsMute: Bool
    /// Seules les zones à plusieurs membres réagissent au clic sur la ligne.
    let isExpandable: Bool
    /// Ligne inactive (enceinte hors ligne) : tout est atténué.
    let isDimmed: Bool
}

/// Une ligne : zone, membre de zone, ou enceinte isolée.
///
/// Une reconstruction du menu la recrée, comme les lignes de source. Mais un
/// simple changement de volume ne passe **pas** par là : `applyVolume` /
/// `applyMute` mettent la ligne à jour sur place, sans toucher au menu. C'est ce
/// qui permet aux enceintes membres de suivre en direct pendant qu'on déplace le
/// slider de leur zone, comme sur le frontend web — un rebuild, lui, est bloqué
/// tant qu'un geste est en cours, donc ne les rattraperait qu'à la fin.
final class MultiroomRowView: NSView {
    var onRowClick: (() -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    /// Paramètre : l'état muet **courant** de la ligne. Il est passé au clic
    /// plutôt que capturé à la construction, parce qu'un mute venu du backend se
    /// propage désormais en place : une fermeture qui aurait figé l'état à la
    /// construction renverrait la bascule inverse de celle qu'on voit à l'écran.
    var onMuteToggle: ((Bool) -> Void)?

    private let iconView = PassthroughImageView()
    private let nameLabel = PassthroughTextField(labelWithString: "")
    private let slider: NativeVolumeSlider
    private let pillLabel = PassthroughTextField(labelWithString: "")
    private let muteButton = MultiroomMuteButton()

    private var trackingArea: NSTrackingArea?
    private var hoverLayer: CALayer?
    private let isRowClickable: Bool
    /// Hors ligne : atténuation permanente, indépendante du mute.
    private let isDimmed: Bool
    /// Faux pour une ligne à pastille (hors ligne, ampli externe) : `applyVolume`
    /// n'a alors rien à mettre à jour.
    private let hasSlider: Bool
    private var isMuted: Bool
    private let showsMute: Bool

    init(model: MultiroomRowModel, nameWidth: CGFloat) {
        self.slider = NativeVolumeSlider(frame: .zero)
        self.isRowClickable = model.isExpandable
        self.isDimmed = model.isDimmed
        self.isMuted = model.muted
        self.showsMute = model.showsMute
        if case .slider = model.control { self.hasSlider = true } else { self.hasSlider = false }

        super.init(frame: NSRect(x: 0, y: 0,
                                 width: MultiroomLayout.rowWidth,
                                 height: MultiroomLayout.rowHeight))
        wantsLayer = true

        let hover = CALayer()
        hover.frame = NSRect(x: 5, y: 0, width: bounds.width - 10, height: bounds.height)
        hover.cornerRadius = 6
        hover.backgroundColor = NSColor.clear.cgColor
        layer?.insertSublayer(hover, at: 0)
        hoverLayer = hover

        let midY = bounds.midY
        let sliderX = MultiroomLayout.sliderOrigin(nameWidth: nameWidth)

        iconView.image = NSImage(systemSymbolName: model.iconSymbol, accessibilityDescription: nil)
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
        iconView.frame = NSRect(x: MultiroomLayout.iconX,
                                y: midY - MultiroomLayout.iconSize / 2,
                                width: MultiroomLayout.iconSize,
                                height: MultiroomLayout.iconSize)
        addSubview(iconView)

        nameLabel.stringValue = model.name
        nameLabel.font = MultiroomLayout.nameFont
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.frame = NSRect(x: MultiroomLayout.nameX,
                                 y: midY - MenuRowMetrics.textHeight / 2,
                                 width: nameWidth,
                                 height: MenuRowMetrics.textHeight)
        addSubview(nameLabel)

        switch model.control {
        case .slider(let volumeDb, let minDb, let maxDb):
            slider.minValue = minDb
            slider.maxValue = max(maxDb, minDb + 1)
            slider.setVolumeValue(volumeDb)
            slider.target = self
            slider.action = #selector(sliderMoved)
            slider.frame = NSRect(x: sliderX,
                                  y: midY - MultiroomLayout.sliderHeight / 2,
                                  width: max(60, MultiroomLayout.sliderEnd - sliderX),
                                  height: MultiroomLayout.sliderHeight)
            addSubview(slider)

        case .pill(let text):
            pillLabel.stringValue = text.uppercased()
            pillLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
            pillLabel.alignment = .center
            pillLabel.textColor = NSColor.secondaryLabelColor
            pillLabel.wantsLayer = true
            pillLabel.layer?.cornerRadius = 9
            pillLabel.layer?.backgroundColor = NSColor.tertiaryLabelColor.withAlphaComponent(0.25).cgColor
            pillLabel.frame = NSRect(x: sliderX, y: midY - 9,
                                     width: MultiroomLayout.sliderEnd - sliderX, height: 18)
            addSubview(pillLabel)
        }

        if model.showsMute {
            muteButton.onClick = { [weak self] in
                guard let self else { return }
                self.onMuteToggle?(self.isMuted)
            }
            muteButton.frame = NSRect(x: MultiroomLayout.muteX,
                                      y: midY - MultiroomLayout.muteSize / 2,
                                      width: MultiroomLayout.muteSize,
                                      height: MultiroomLayout.muteSize)
            addSubview(muteButton)
        }

        alphaValue = model.isDimmed ? 0.55 : 1.0
        applyMuteStyling()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // MARK: - Mise à jour en place

    /// Recale le slider sur une nouvelle valeur serveur sans reconstruire la ligne.
    ///
    /// Le slider sous la souris est laissé tranquille : c'est l'utilisateur qui
    /// mène, et l'écho serveur qu'on recevrait en plein geste est en retard d'un
    /// aller-retour.
    func applyVolume(_ volumeDb: Double) {
        guard hasSlider, !NativeVolumeSlider.isDragging(slider) else { return }
        guard abs(slider.doubleValue - volumeDb) >= 0.1 else { return }
        // Interpolation courte plutôt qu'un saut : pendant qu'on déplace le
        // slider d'une zone, ses membres reçoivent un écho tous les ~80 ms et
        // glissent au lieu de sauter par paliers. Elle reste plus courte que
        // l'animation par défaut du slider (0,25 s), qui à cette cadence serait
        // toujours en retard d'un tick.
        slider.setVolumeValue(volumeDb, duration: MultiroomLayout.volumeGlideDuration)
    }

    func applyMute(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        applyMuteStyling()
    }

    /// Le mute atténue tout ce que porte la ligne — icône, nom, slider — sans
    /// interdire le réglage : on peut régler le volume d'une enceinte muette,
    /// comme sur le frontend web.
    private func applyMuteStyling() {
        let dimmed = isDimmed || isMuted
        iconView.contentTintColor = dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
        nameLabel.textColor = dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor
        if hasSlider { slider.alphaValue = isMuted ? 0.45 : 1.0 }
        if showsMute { muteButton.configure(muted: isMuted) }
    }

    @objc private func sliderMoved(_ sender: NSSlider) {
        onVolumeChange?(sender.doubleValue)
    }

    /// Le premier clic après l'ouverture du menu doit atteindre le slider plutôt
    /// que d'être consommé pour activer la fenêtre — même raison que
    /// `MenuInteractionView`, qui porte le slider du menu principal.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds,
                                  options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    private func setHover(_ active: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hoverLayer?.backgroundColor = (active && isRowClickable)
            ? NSColor.tertiaryLabelColor.cgColor
            : NSColor.clear.cgColor
        CATransaction.commit()
    }

    override func mouseEntered(with event: NSEvent) { setHover(true) }
    override func mouseExited(with event: NSEvent) { setHover(false) }

    /// On avale le clic même quand la ligne n'est pas dépliable, pour que le
    /// `NSMenu` ne le traite pas comme une sélection.
    override func mouseDown(with event: NSEvent) {
        guard isRowClickable else { return }
        setHover(false)
        onRowClick?()
    }
}

// MARK: - Construction de la section

/// Fabrique les lignes insérées sous l'en-tête « Multiroom » du menu principal,
/// et porte le dépliage de chaque zone.
///
/// La section n'a pas d'état déplié/replié qui lui soit propre : elle existe tant
/// que le multiroom est actif, ce que dit l'interrupteur de l'en-tête.
///
/// Pas de `NSMenu` persistant ni de diff d'identités ici, contrairement au
/// sous-menu radio : les lignes vivent dans le menu principal, que
/// `MenuBarController` reconstruit déjà en entier de façon coalescée.
///
/// Les **volumes et les mutes** font exception : `applyInPlace` les pousse dans
/// les lignes déjà affichées, sans reconstruction. Un `volume/volume_changed`
/// arrive à chaque tick d'un drag ; le faire passer par un rebuild complet
/// détruisait et recréait tous les sliders (y compris celui du volume principal)
/// plusieurs fois par seconde, et pendant un geste le rebuild étant bloqué, les
/// autres lignes ne rattrapaient l'état serveur qu'à la fin du drag. C'est la
/// double cause des à-coups que n'a pas le frontend web, où le DOM se contente
/// de re-rendre les valeurs.
final class MultiroomSectionBuilder {
    private var expandedZones: Set<String> = []

    private let volumeController: MultiroomVolumeController

    /// Lignes actuellement dans le menu, adressables pour une mise à jour en
    /// place. Vidé dès que le menu est reconstruit ou fermé : une vue qui n'est
    /// plus dans le menu ne doit plus être mise à jour.
    private var liveRows: [RowKey: MultiroomRowView] = [:]
    /// Structure des lignes affichées, pour décider si une mise à jour en place
    /// suffit.
    private var liveSignature: [RowSignature] = []
    private var liveNameWidth: CGFloat = 0
    /// Bornes des sliders affichés. Elles ne sont posées qu'à la construction :
    /// si le backend les change en direct, une mise à jour en place placerait le
    /// pouce sur la mauvaise échelle — il faut reconstruire.
    private var liveLimits: (minDb: Double, maxDb: Double)?

    /// Rejoué après un dépliage pour que le menu se reconstruise.
    var onNeedsRefresh: (() -> Void)?

    init(volumeController: MultiroomVolumeController) {
        self.volumeController = volumeController
    }

    func reset() {
        expandedZones.removeAll()
        invalidateLiveRows()
    }

    /// À appeler avant toute reconstruction du menu et à sa fermeture.
    func invalidateLiveRows() {
        liveRows.removeAll()
        liveSignature.removeAll()
        liveNameWidth = 0
        liveLimits = nil
    }

    /// Pousse les nouveaux volumes/mutes dans les lignes déjà affichées.
    ///
    /// - Returns: `true` si l'affichage est à jour — soit qu'on ait tout appliqué,
    ///   soit qu'aucune ligne ne soit à l'écran. `false` quand la structure a
    ///   changé (ligne apparue, passée hors ligne, renommée…) : seul un rebuild
    ///   peut la refléter.
    func applyInPlace(items: [MultiroomDisplayItem],
                      limits: (minDb: Double, maxDb: Double)) -> Bool {
        guard !liveRows.isEmpty else { return true }
        guard let liveLimits, liveLimits == limits else { return false }

        let rows = flatten(items: items, limits: limits)
        guard computeNameWidth(rows: rows) == liveNameWidth,
              rows.map(\.signature) == liveSignature else { return false }

        for row in rows {
            guard let view = liveRows[row.key] else { return false }
            view.applyMute(row.model.muted)
            if let volumeDb = row.displayVolumeDb { view.applyVolume(volumeDb) }
        }
        return true
    }

    /// Lignes à insérer sous l'en-tête « Multiroom ».
    func makeItems(items: [MultiroomDisplayItem],
                   limits: (minDb: Double, maxDb: Double)) -> [NSMenuItem] {
        // Purger les zones dépliées disparues, sinon l'ensemble grossit au fil
        // des reconfigurations.
        let liveZoneIds = Set(items.compactMap { item -> String? in
            if case .zone(let zone) = item { return zone.id }
            return nil
        })
        expandedZones.formIntersection(liveZoneIds)

        invalidateLiveRows()

        guard !items.isEmpty else {
            let empty = NSMenuItem(title: L("multiroom.noClients"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return [empty]
        }

        let rows = flatten(items: items, limits: limits)
        let nameWidth = computeNameWidth(rows: rows)
        liveNameWidth = nameWidth
        liveSignature = rows.map(\.signature)
        liveLimits = limits

        return rows.map { row in
            let view = MultiroomRowView(model: row.model, nameWidth: nameWidth)
            liveRows[row.key] = view

            if let zoneId = row.expandableZoneId {
                view.onRowClick = { [weak self] in self?.toggleZone(zoneId) }
            }
            if let target = row.sliderTarget {
                let fallbackServerValue = row.serverVolumeDb
                view.onVolumeChange = { [weak self] value in
                    self?.volumeController.handleVolumeChange(target: target,
                                                              newValue: value,
                                                              fallbackServerValue: fallbackServerValue)
                }
            }
            if let muteTarget = row.muteTarget {
                // `members` vient de la topologie, que seul un rebuild peut faire
                // changer : le capturer reste juste. L'état muet, lui, est celui
                // que la ligne porte au moment du clic.
                let members = row.zoneMembers
                view.onMuteToggle = { [weak self] currentlyMuted in
                    self?.volumeController.toggleMute(target: muteTarget,
                                                      currentlyMuted: currentlyMuted,
                                                      zoneMembers: members)
                }
            }

            // Aucune action sur l'item : le menu principal laisse
            // `autoenablesItems` à son défaut (true), qui désactive tout item
            // sans action. Or `NSMenu` lit un mouseUp au-dessus d'un item ACTIVÉ
            // comme une sélection et se referme — c'est ce qui fermerait le menu
            // au relâchement d'un slider. Le slider de volume du menu principal
            // repose sur exactement la même configuration.
            let item = NSMenuItem()
            item.view = view
            return item
        }
    }

    // MARK: - Aplatissement

    /// Identité d'une ligne, stable d'une reconstruction à l'autre. Distincte de
    /// `Target` : une ligne hors ligne ou en volume externe n'a pas de cible de
    /// volume mais reste identifiable.
    private enum RowKey: Hashable {
        case zone(String)
        case client(String)
    }

    /// Tout ce qui, en changeant, impose une vraie reconstruction : ordre des
    /// lignes, libellés, géométrie, nature du contrôle. Le volume et le mute en
    /// sont volontairement absents — ce sont eux qu'on sait appliquer en place.
    private struct RowSignature: Equatable {
        let key: RowKey
        let iconSymbol: String
        let name: String
        /// Nil pour un slider, sinon le texte de la pastille.
        let pillText: String?
        let showsMute: Bool
        let isExpandable: Bool
        let isDimmed: Bool
    }

    private struct FlatRow {
        let key: RowKey
        let model: MultiroomRowModel
        /// Non-nil quand un clic sur la ligne déplie/replie cette zone.
        let expandableZoneId: String?
        /// Cible du slider — nil quand la ligne n'en a pas (hors ligne, DAC).
        let sliderTarget: MultiroomVolumeController.Target?
        /// Cible du mute, distincte : une zone hors ligne ou en volume externe n'a
        /// pas de slider mais garde son bouton mute.
        let muteTarget: MultiroomVolumeController.Target?
        /// Valeur **serveur** brute, avant substitution de la valeur locale
        /// optimiste. Elle sert de repli pour ancrer le servo de delta d'une zone :
        /// le contrôleur préfère son propre cache d'état serveur, qui reste frais
        /// pendant un geste alors que cette copie-ci est figée à la construction
        /// de la ligne. Ancrer sur la valeur *affichée* ferait, elle, cumuler
        /// l'erreur d'un geste au suivant.
        let serverVolumeDb: Double
        /// Membres en ligne d'une zone, pour le mute (pas d'endpoint atomique).
        let zoneMembers: [String]

        var signature: RowSignature {
            let pillText: String?
            if case .pill(let text) = model.control { pillText = text } else { pillText = nil }
            return RowSignature(key: key,
                                iconSymbol: model.iconSymbol,
                                name: model.name,
                                pillText: pillText,
                                showsMute: model.showsMute,
                                isExpandable: model.isExpandable,
                                isDimmed: model.isDimmed)
        }

        /// Volume à afficher, nil pour une ligne à pastille.
        var displayVolumeDb: Double? {
            if case .slider(let volumeDb, _, _) = model.control { return volumeDb }
            return nil
        }
    }

    private func flatten(items: [MultiroomDisplayItem],
                         limits: (minDb: Double, maxDb: Double)) -> [FlatRow] {
        var rows: [FlatRow] = []

        for item in items {
            switch item {
            case .client(let client):
                rows.append(clientRow(client, limits: limits))

            case .zone(let zone):
                let isZoneExpanded = expandedZones.contains(zone.id)
                let target = MultiroomVolumeController.Target.zone(zone.id)
                let muted = volumeController.displayMute(for: target, serverValue: zone.muted)

                let control: MultiroomRowControl
                if !zone.anyOnline {
                    control = .pill(L("multiroom.offline"))
                } else if zone.allExternalVolume {
                    control = .pill(L("multiroom.externalVolume"))
                } else {
                    control = .slider(
                        volumeDb: volumeController.displayVolume(for: target, serverValue: zone.volumeDb),
                        minDb: limits.minDb,
                        maxDb: limits.maxDb
                    )
                }

                rows.append(FlatRow(
                    key: .zone(zone.id),
                    model: MultiroomRowModel(
                        iconSymbol: zone.isExpandable
                            ? (isZoneExpanded ? "chevron.down" : "chevron.right")
                            : "rectangle.3.group",
                        name: zone.name,
                        control: control,
                        muted: muted,
                        showsMute: zone.anyOnline,
                        isExpandable: zone.isExpandable,
                        isDimmed: !zone.anyOnline
                    ),
                    expandableZoneId: zone.isExpandable ? zone.id : nil,
                    sliderTarget: zone.hasSlider ? target : nil,
                    muteTarget: zone.anyOnline ? target : nil,
                    serverVolumeDb: zone.volumeDb,
                    zoneMembers: zone.clients.filter { $0.online }.map { $0.macId }
                ))

                if isZoneExpanded {
                    rows.append(contentsOf: zone.clients.map { clientRow($0, limits: limits) })
                }
            }
        }

        return rows
    }

    private func clientRow(_ client: MultiroomDisplayClient,
                           limits: (minDb: Double, maxDb: Double)) -> FlatRow {
        let target = MultiroomVolumeController.Target.client(client.macId)
        let muted = volumeController.displayMute(for: target, serverValue: client.muted)

        let control: MultiroomRowControl
        if !client.online {
            control = .pill(L("multiroom.offline"))
        } else if !client.volumeControl {
            control = .pill(L("multiroom.externalVolume"))
        } else {
            control = .slider(
                volumeDb: volumeController.displayVolume(for: target, serverValue: client.volumeDb),
                minDb: limits.minDb,
                maxDb: limits.maxDb
            )
        }

        return FlatRow(
            key: .client(client.macId),
            model: MultiroomRowModel(
                iconSymbol: Self.speakerSymbol(for: client.speakerType),
                name: client.name,
                control: control,
                muted: muted,
                showsMute: client.online,
                isExpandable: false,
                isDimmed: !client.online
            ),
            expandableZoneId: nil,
            sliderTarget: client.hasSlider ? target : nil,
            muteTarget: client.online ? target : nil,
            serverVolumeDb: client.volumeDb,
            zoneMembers: []
        )
    }

    private func toggleZone(_ zoneId: String) {
        if expandedZones.contains(zoneId) {
            expandedZones.remove(zoneId)
        } else {
            expandedZones.insert(zoneId)
        }
        onNeedsRefresh?()
    }

    // MARK: - Helpers

    /// Aligne toutes les colonnes de noms sur le plus large (plafonné), pour que
    /// les sliders démarrent au même x — l'équivalent du `--name-width` du web.
    private func computeNameWidth(rows: [FlatRow]) -> CGFloat {
        let attributes: [NSAttributedString.Key: Any] = [.font: MultiroomLayout.nameFont]
        var widest: CGFloat = 0
        for row in rows {
            widest = max(widest, (row.model.name as NSString).size(withAttributes: attributes).width)
        }
        return min(max(widest.rounded(.up) + 4, MultiroomLayout.minNameWidth),
                   MultiroomLayout.maxNameWidth)
    }

    /// Types d'enceinte du backend → SF Symbols. Le frontend web a quatre SVG
    /// maison ; on reste sur des symboles système, plus dans le ton d'un menu macOS.
    private static func speakerSymbol(for speakerType: String) -> String {
        switch speakerType {
        case "satellite":  return "hifispeaker"
        case "tower":      return "hifispeaker.2.fill"
        case "subwoofer":  return "speaker.wave.1.fill"
        default:           return "hifispeaker.fill"   // bookshelf
        }
    }
}
