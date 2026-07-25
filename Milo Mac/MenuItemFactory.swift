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
    static func createSystemControlsSection(state: MiloState?, loadingStates: [String: Bool] = [:], enabledApps: [String]? = nil, target: AnyObject, action: Selector) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(createSecondaryHeader(title: L("menu.features.title")))

        var systemConfigs: [(String, String, String, Bool)] = []

        if enabledApps?.contains("multiroom") ?? true {
            systemConfigs.append((L("feature.multiroom"), "speaker.wave.3", "multiroom", state?.multiroomEnabled ?? false))
        }
        if enabledApps?.contains("equalizer") ?? false {
            systemConfigs.append((L("feature.equalizer"), "slider.horizontal.3", "equalizer", state?.equalizerEnabled ?? true))
        }

        for (title, iconName, toggleId, currentlyEnabled) in systemConfigs {
            let isLoading = loadingStates[toggleId] == true
            let isActive = isLoading || (!isLoading && currentlyEnabled)

            let config = MenuItemConfig(
                title: title,
                iconName: iconName,
                isActive: isActive,
                target: target,
                action: action,
                representedObject: toggleId
            )

            items.append(CircularMenuItem.createWithLoadingSupport(
                with: config,
                isLoading: isLoading,
                loadingIsActive: isLoading
            ))
        }

        return items
    }

    // MARK: - Disconnected State
    static func createDisconnectedItem() -> NSMenuItem {
        let item = NSMenuItem(title: L("status.disconnected"), action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    // MARK: - Helper Methods
    private static func createSecondaryHeader(title: String) -> NSMenuItem {
        let item = NSMenuItem()
        let headerView = NSView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: 22))

        let titleLabel = createLabel(text: title, font: .systemFont(ofSize: 12, weight: .bold))
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
