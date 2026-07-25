import AppKit

// MARK: - Géométrie

/// Les lignes s'insèrent dans le menu principal, sous « Multiroom » : elles font
/// donc exactement la largeur des autres lignes (300 px). `NSMenu` se dimensionne
/// sur sa vue la plus large — une ligne plus large décalerait tout le reste.
private enum MultiroomLayout {
    static let rowWidth = MenuRowMetrics.containerWidth
    static let rowHeight = MenuRowMetrics.containerHeight

    /// Boîte du glyphe (caret de zone, haut-parleur d'enceinte). Elle est centrée
    /// sur l'axe des pastilles des lignes de source, pas posée à sa propre marge :
    /// les deux familles de lignes partagent ainsi le même axe d'icônes.
    static let iconSize: CGFloat = 20
    static let iconX = MenuRowMetrics.circleCenterX - iconSize / 2

    /// Les noms s'alignent sur la colonne de texte des lignes de source.
    static let nameX = MenuRowMetrics.textLeftMargin

    static let muteSize: CGFloat = 24
    static let muteX = rowWidth - MenuRowMetrics.rightMargin - muteSize
    static let sliderEnd = muteX - 10
    static let sliderHeight: CGFloat = 22

    /// Zones et enceintes partagent le même bord gauche (pas d'indentation des
    /// membres) : la zone se reconnaît à son chevron, l'enceinte à son icône de
    /// haut-parleur. Tous les sliders démarrent ainsi sur la même colonne.
    ///
    /// Le plafond de largeur des noms garantit qu'il reste ~86 px de slider dans
    /// le pire cas. À 300 px, il n'y a pas la place d'afficher en plus la valeur
    /// en dB que montre le frontend web.
    static let minNameWidth: CGFloat = 70
    static let maxNameWidth: CGFloat = 110

    static func sliderOrigin(nameWidth: CGFloat) -> CGFloat {
        nameX + nameWidth + 10
    }
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
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
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
/// Vivant dans le menu principal, elle est **recréée** à chaque reconstruction du
/// menu, comme les lignes de source — pas de mise à jour en place ici. C'est le
/// garde d'interaction de `MenuBarController.flushMenuRefresh` qui empêche qu'un
/// rebuild survienne pendant qu'un slider est manipulé.
final class MultiroomRowView: NSView {
    var onRowClick: (() -> Void)?
    var onVolumeChange: ((Double) -> Void)?
    var onMuteToggle: (() -> Void)?

    private let iconView = PassthroughImageView()
    private let nameLabel = PassthroughTextField(labelWithString: "")
    private let slider: NativeVolumeSlider
    private let pillLabel = PassthroughTextField(labelWithString: "")
    private let muteButton = MultiroomMuteButton()

    private var trackingArea: NSTrackingArea?
    private var hoverLayer: CALayer?
    private let isRowClickable: Bool

    init(model: MultiroomRowModel, nameWidth: CGFloat) {
        self.slider = NativeVolumeSlider(frame: .zero)
        self.isRowClickable = model.isExpandable

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
        let dimmed = model.isDimmed || model.muted

        iconView.image = NSImage(systemSymbolName: model.iconSymbol, accessibilityDescription: nil)
        iconView.contentTintColor = dimmed ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor
        iconView.imageScaling = .scaleProportionallyDown
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.frame = NSRect(x: MultiroomLayout.iconX,
                                y: midY - MultiroomLayout.iconSize / 2,
                                width: MultiroomLayout.iconSize,
                                height: MultiroomLayout.iconSize)
        addSubview(iconView)

        nameLabel.stringValue = model.name
        nameLabel.font = NSFont.menuFont(ofSize: 13)
        nameLabel.textColor = dimmed ? NSColor.tertiaryLabelColor : NSColor.labelColor
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
            // Le mute atténue le réglage sans l'interdire : on peut régler le
            // volume d'une enceinte muette, comme sur le frontend web.
            slider.alphaValue = model.muted ? 0.45 : 1.0
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
            muteButton.configure(muted: model.muted)
            muteButton.onClick = { [weak self] in self?.onMuteToggle?() }
            muteButton.frame = NSRect(x: MultiroomLayout.muteX,
                                      y: midY - MultiroomLayout.muteSize / 2,
                                      width: MultiroomLayout.muteSize,
                                      height: MultiroomLayout.muteSize)
            addSubview(muteButton)
        }

        alphaValue = model.isDimmed ? 0.55 : 1.0
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

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

/// Fabrique les lignes insérées sous « Multiroom » dans le menu principal, et
/// porte l'état de dépliage (la section entière, et chaque zone).
///
/// Pas de `NSMenu` persistant ni de diff d'identités ici, contrairement au
/// sous-menu radio : les lignes vivent dans le menu principal, que
/// `MenuBarController` reconstruit déjà en entier de façon coalescée.
final class MultiroomSectionBuilder {
    /// Section **dépliée** par défaut : dès que le multiroom est actif, ses zones
    /// et enceintes sont ce qu'on vient voir. Le caret de la ligne « Multiroom »
    /// pointe donc vers le bas à l'ouverture (convention macOS : `chevron.down`
    /// = déplié), et sert à replier.
    private(set) var isExpanded = true
    private var expandedZones: Set<String> = []

    private let volumeController: MultiroomVolumeController

    /// Rejoué après un dépliage pour que le menu se reconstruise.
    var onNeedsRefresh: (() -> Void)?

    init(volumeController: MultiroomVolumeController) {
        self.volumeController = volumeController
    }

    func toggleExpanded() {
        isExpanded.toggle()
        onNeedsRefresh?()
    }

    func reset() {
        isExpanded = true
        expandedZones.removeAll()
    }

    /// Lignes à insérer sous « Multiroom ». Vide quand la section est repliée.
    func makeItems(items: [MultiroomDisplayItem],
                   limits: (minDb: Double, maxDb: Double)) -> [NSMenuItem] {
        guard isExpanded else { return [] }

        // Purger les zones dépliées disparues, sinon l'ensemble grossit au fil
        // des reconfigurations.
        let liveZoneIds = Set(items.compactMap { item -> String? in
            if case .zone(let zone) = item { return zone.id }
            return nil
        })
        expandedZones.formIntersection(liveZoneIds)

        guard !items.isEmpty else {
            let empty = NSMenuItem(title: L("multiroom.noClients"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            return [empty]
        }

        let rows = flatten(items: items, limits: limits)
        let nameWidth = computeNameWidth(rows: rows)

        return rows.map { row in
            let view = MultiroomRowView(model: row.model, nameWidth: nameWidth)

            if let zoneId = row.expandableZoneId {
                view.onRowClick = { [weak self] in self?.toggleZone(zoneId) }
            }
            if let target = row.sliderTarget {
                let serverValue = row.serverVolumeDb
                view.onVolumeChange = { [weak self] value in
                    self?.volumeController.handleVolumeChange(target: target,
                                                              newValue: value,
                                                              serverValue: serverValue)
                }
            }
            if let muteTarget = row.muteTarget {
                let muted = row.model.muted
                let members = row.zoneMembers
                view.onMuteToggle = { [weak self] in
                    self?.volumeController.toggleMute(target: muteTarget,
                                                      currentlyMuted: muted,
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

    private struct FlatRow {
        let model: MultiroomRowModel
        /// Non-nil quand un clic sur la ligne déplie/replie cette zone.
        let expandableZoneId: String?
        /// Cible du slider — nil quand la ligne n'en a pas (hors ligne, DAC).
        let sliderTarget: MultiroomVolumeController.Target?
        /// Cible du mute, distincte : une zone hors ligne ou en volume externe n'a
        /// pas de slider mais garde son bouton mute.
        let muteTarget: MultiroomVolumeController.Target?
        /// Valeur **serveur** brute, avant substitution de la valeur locale
        /// optimiste : c'est elle qui ancre le servo de delta d'une zone. Ancrer
        /// sur la valeur affichée ferait cumuler l'erreur d'un geste au suivant.
        let serverVolumeDb: Double
        /// Membres en ligne d'une zone, pour le mute (pas d'endpoint atomique).
        let zoneMembers: [String]
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
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.menuFont(ofSize: 13)]
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
