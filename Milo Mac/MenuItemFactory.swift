import SwiftUI
import AppKit

class MenuItemFactory {
    // MARK: - Constants
    private static let containerWidth: CGFloat = 300
    private static let sideMargin: CGFloat = 12
    private static let rightMargin: CGFloat = 14

    // MARK: - Volume Section
    static func createVolumeSection(volumeDb: Double, limitMinDb: Double, limitMaxDb: Double, target: AnyObject, action: Selector) -> [NSMenuItem] {
        return [
            createVolumeHeader(),
            createVolumeSlider(volumeDb: volumeDb, limitMinDb: limitMinDb, limitMaxDb: limitMaxDb, target: target, action: action),
            NSMenuItem.separator()
        ]
    }

    private static func createVolumeHeader() -> NSMenuItem {
        let item = NSMenuItem()
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 28))

        let titleLabel = createLabel(text: L("menu.volume.title"), font: .systemFont(ofSize: 13, weight: .semibold))
        titleLabel.frame = NSRect(x: sideMargin, y: 4, width: 160, height: 16)

        headerView.addSubview(titleLabel)
        item.view = headerView

        return item
    }

    private static func createVolumeSlider(volumeDb: Double, limitMinDb: Double, limitMaxDb: Double, target: AnyObject, action: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let containerView = MenuInteractionView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 31))

        let slider = NativeVolumeSlider(frame: NSRect(x: rightMargin, y: 5, width: containerWidth - (rightMargin * 2), height: 22))
        slider.minValue = limitMinDb
        slider.maxValue = limitMaxDb
        slider.doubleValue = volumeDb
        slider.target = target
        slider.action = action

        containerView.addSubview(slider)
        item.view = containerView

        return item
    }

    // MARK: - Audio Sources Section

    private static let allSourceConfigs: [(title: () -> String, iconName: String, sourceId: String)] = [
        ({ L("source.spotify") }, "music.note", "spotify"),
        ({ L("source.bluetooth") }, "bluetooth", "bluetooth"),
        ({ L("source.radio") }, "radio", "radio"),
        ({ L("source.podcast") }, "podcasts-icon", "podcast"),
        ({ L("source.airplay") }, "airplayaudio", "airplay"),
        ({ L("source.mac") }, "desktopcomputer", "mac"),
        ({ L("source.cd") }, "cd-icon", "cd"),
        ({ L("source.dlna") }, "dlna-icon", "dlna"),
        ({ L("source.qobuz") }, "qobuz-icon", "qobuz"),
        ({ L("source.music_library") }, "music-library-icon", "music_library")
    ]

    static let allSourceIds: [String] = allSourceConfigs.map { $0.sourceId }

    static func createAudioSourcesSection(state: MiloState?, loadingStates: [String: Bool] = [:], enabledApps: [String]? = nil, target: AnyObject, action: Selector, longPressAction: Selector? = nil) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(createSecondaryHeader(title: L("menu.audio_sources.title")))

        let activeSource = state?.activeSource ?? "none"
        let isSourceTransitioning = (state?.sourceState.lowercased() == "starting") || (state?.transitioning ?? false)

        let configMap = Dictionary(uniqueKeysWithValues: allSourceConfigs.map { ($0.sourceId, $0) })

        // Use enabledApps order, filtering to audio sources only; fallback to default order
        let orderedSourceIds: [String]
        if let enabledApps = enabledApps {
            orderedSourceIds = enabledApps.filter { configMap[$0] != nil }
        } else {
            orderedSourceIds = allSourceConfigs.map { $0.sourceId }
        }

        for sourceId in orderedSourceIds {
            guard let source = configMap[sourceId] else { continue }

            // Spinner si le backend signale une transition vers cette source OU
            // si un clic local vient de partir (loadingStates, posé par
            // MenuBarController avant la requête HTTP).
            let isLoading = (isSourceTransitioning && activeSource == sourceId) || (loadingStates[sourceId] == true)
            let isActive = (activeSource == sourceId)

            let config = MenuItemConfig(
                title: source.title(),
                iconName: source.iconName,
                isActive: isActive,
                target: target,
                action: action,
                representedObject: sourceId,
                // Seule la source active se ferme à l'appui maintenu ; on
                // n'arme pas le geste pendant une transition déjà en vol.
                longPressAction: (isActive && !isLoading) ? longPressAction : nil
            )

            items.append(CircularMenuItem.createWithLoadingSupport(
                with: config,
                isLoading: isLoading,
                loadingIsActive: isLoading
            ))
        }

        items.append(NSMenuItem.separator())
        return items
    }

    // MARK: - System Controls Section

    /// Hauteur d'une ligne de fonctionnalité : les 22 px d'un en-tête de section,
    /// plus la marge qu'exige l'interrupteur.
    private static let featureRowHeight: CGFloat = 24
    /// Taille intrinsèque d'un `NSSwitch` en `.mini` (mesurée, pas devinée) — la
    /// plus petite taille système, celle qui pèse le moins face à un en-tête.
    private static let switchSize = NSSize(width: 26, height: 15)
    private static let switchControlSize = NSControl.ControlSize.mini
    /// Pulsation du toggle pendant la bascule. Mise à `nil`, la ligne se contente
    /// du grisé natif.
    private static let togglePulseDuration: CFTimeInterval? = 0.9

    /// Chaque fonctionnalité est un en-tête de section portant son interrupteur à
    /// droite : « Multiroom » se prolonge par ses zones et enceintes, « Égaliseur »
    /// n'a rien dessous mais garde exactement la même présentation.
    ///
    /// Plus de section « Fonctionnalités » qui les regrouperait : elle s'affichait
    /// même quand le backend n'exposait ni l'un ni l'autre.
    static func createSystemControlsSection(state: MiloState?,
                                            loadingStates: [String: Bool] = [:],
                                            pendingStates: [String: Bool] = [:],
                                            enabledApps: [String]? = nil,
                                            target: AnyObject,
                                            action: Selector) -> [NSMenuItem] {
        var systemConfigs: [(title: String, toggleId: String, isEnabled: Bool)] = []

        if enabledApps?.contains("multiroom") ?? true {
            systemConfigs.append((L("feature.multiroom"), "multiroom", state?.multiroomEnabled ?? false))
        }
        if enabledApps?.contains("equalizer") ?? false {
            systemConfigs.append((L("feature.equalizer"), "equalizer", state?.equalizerEnabled ?? true))
        }

        var items: [NSMenuItem] = []

        for (index, config) in systemConfigs.enumerated() {
            // Séparateur entre deux sections uniquement : en tête il doublerait
            // celui qui ferme déjà la section des sources.
            if index > 0 { items.append(NSMenuItem.separator()) }

            let isLoading = loadingStates[config.toggleId] == true

            items.append(createFeatureToggleRow(
                title: config.title,
                // Pendant la bascule, l'interrupteur montre déjà l'état visé —
                // sinon une extinction s'afficherait allumée pendant 35 s.
                isOn: isLoading ? (pendingStates[config.toggleId] ?? !config.isEnabled) : config.isEnabled,
                isLoading: isLoading,
                target: target,
                action: action,
                representedObject: config.toggleId
            ))
        }

        return items
    }

    /// Ligne « titre + interrupteur ». Le conteneur est un `HoverableView` comme
    /// les lignes de source : il traite `mouseDown` sur place, sans jamais laisser
    /// le `NSMenu` interpréter le relâchement comme une sélection.
    private static func createFeatureToggleRow(title: String,
                                               isOn: Bool,
                                               isLoading: Bool,
                                               target: AnyObject,
                                               action: Selector,
                                               representedObject: String) -> NSMenuItem {
        let item = NSMenuItem()
        item.target = target
        item.action = action
        item.representedObject = representedObject

        let container = HoverableView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: featureRowHeight))

        // Capture weak des deux côtés — même raison que CircularMenuItem : l'item
        // retient la vue, la vue retient la closure.
        container.clickHandler = { [weak target, weak item] in
            guard let item else { return }
            _ = target?.perform(action, with: item)
        }
        // Toute la ligne bascule, pas seulement les 26 px du contrôle. Le clic
        // pendant un chargement est absorbé par le garde de `toggleClicked`.
        container.configureHoverBackground(leftMargin: 5, rightMargin: 5)

        // Exactement la typo des en-têtes de section (« Sortie ») : c'est un
        // en-tête, pas une entrée de liste. Éteinte, la fonctionnalité reprend
        // même la couleur d'un en-tête ; allumée, elle passe en pleine encre.
        let titleLabel = createLabel(text: title, font: secondaryHeaderFont)
        titleLabel.textColor = isOn ? NSColor.labelColor : NSColor.secondaryLabelColor
        titleLabel.frame = NSRect(x: sideMargin,
                                  y: (featureRowHeight - 16) / 2,
                                  width: containerWidth - sideMargin - rightMargin - switchSize.width - 12,
                                  height: 16)
        container.addSubview(titleLabel)

        let toggle = PassthroughSwitch()
        toggle.controlSize = switchControlSize
        toggle.state = isOn ? .on : .off
        // Grisé natif pendant la bascule : le contrôle se lit comme verrouillé
        // sans qu'on ait à lui adjoindre un spinner.
        toggle.isEnabled = !isLoading
        toggle.frame = NSRect(x: containerWidth - rightMargin - switchSize.width,
                              y: (featureRowHeight - switchSize.height) / 2,
                              width: switchSize.width,
                              height: switchSize.height)
        toggle.setAccessibilityLabel(title)
        container.addSubview(toggle)

        // Une bascule multiroom prend jusqu'à 35 s : un contrôle figé s'y lit
        // comme un plantage. La pulsation joue le rôle d'indicateur d'activité
        // sans ajouter d'élément à la ligne.
        if isLoading, let pulseDuration = togglePulseDuration {
            toggle.wantsLayer = true
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.4
            pulse.duration = pulseDuration
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            toggle.layer?.add(pulse, forKey: "loadingPulse")
        }

        item.view = container
        return item
    }

    // MARK: - Disconnected State
    static func createDisconnectedItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("status.disconnected"), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Helper Methods

    /// Police des en-têtes de section (« Sortie »), partagée avec les en-têtes de
    /// fonctionnalité pour qu'ils ne dérivent pas l'un de l'autre.
    private static let secondaryHeaderFont = NSFont.systemFont(ofSize: 12, weight: .bold)

    private static func createSecondaryHeader(title: String) -> NSMenuItem {
        let item = NSMenuItem()
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 22))

        let titleLabel = createLabel(text: title, font: secondaryHeaderFont)
        titleLabel.textColor = NSColor.secondaryLabelColor
        titleLabel.frame = NSRect(x: sideMargin, y: 2, width: 160, height: 16)

        headerView.addSubview(titleLabel)
        item.view = headerView

        return item
    }

    private static func createLabel(text: String, font: NSFont) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = font
        label.textColor = NSColor.labelColor
        label.isEditable = false
        label.isBordered = false
        label.backgroundColor = NSColor.clear
        return label
    }
}

// MARK: - Passthrough Switch

/// `NSSwitch` purement décoratif : il dessine l'état natif — donc exactement le
/// rendu système, sur toutes les versions de macOS — mais `hitTest` le rend
/// transparent à la souris, comme les libellés des lignes multiroom.
///
/// Le clic revient ainsi à `HoverableView`, qui traite `mouseDown` sur place. Un
/// `NSSwitch` laissé cliquable entrerait dans sa propre boucle de tracking et
/// rendrait la main au `NSMenu` sur le `mouseUp` — le profil exact de
/// `NativeVolumeSlider`, seul contrôle de ce menu soupçonné de le refermer.
final class PassthroughSwitch: NSSwitch {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

// MARK: - Menu Interaction View
class MenuInteractionView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }

    override var acceptsFirstResponder: Bool {
        return true
    }

    override func becomeFirstResponder() -> Bool {
        return true
    }

    override func resignFirstResponder() -> Bool {
        return true
    }
}
