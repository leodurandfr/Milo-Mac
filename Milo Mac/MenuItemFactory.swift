import SwiftUI
import AppKit

class MenuItemFactory {
    // MARK: - Constants
    private static let iconSize: CGFloat = 16
    private static let circleSize: CGFloat = 26
    private static let circleMargin: CGFloat = 3
    private static let containerWidth: CGFloat = 300
    private static let containerHeight: CGFloat = 32
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
    
    // MARK: - Configuration Items
    static func createVolumeDeltaConfigItem(currentDeltaDb: Double, target: AnyObject, decreaseAction: Selector, increaseAction: Selector) -> NSMenuItem {
        let item = NSMenuItem()
        let containerView = MenuInteractionView(frame: NSRect(x: 0, y: 0, width: containerWidth, height: containerHeight))

        let titleLabel = createLabel(text: L("config.volume_delta.title"), font: .menuFont(ofSize: 13))
        titleLabel.frame = NSRect(x: sideMargin, y: 8, width: 120, height: 16)

        let controls = createDeltaControls(currentDeltaDb: currentDeltaDb, target: target, decreaseAction: decreaseAction, increaseAction: increaseAction)

        containerView.addSubview(titleLabel)
        controls.forEach { containerView.addSubview($0) }

        item.view = containerView
        item.representedObject = [
            "decrease": controls[1], // decreaseButton
            "increase": controls[2], // increaseButton
            "value": controls[0]     // valueLabel
        ]

        return item
    }

    private static func createDeltaControls(currentDeltaDb: Double, target: AnyObject, decreaseAction: Selector, increaseAction: Selector) -> [NSView] {
        let valueLabel = createLabel(text: "\(Int(currentDeltaDb)) dB", font: .monospacedDigitSystemFont(ofSize: 13, weight: .medium))
        valueLabel.alignment = .center
        valueLabel.frame = NSRect(x: containerWidth - 76, y: 8, width: 34, height: 16)

        let decreaseButton = createDeltaButton(title: L("button.decrease"), target: target, action: decreaseAction, enabled: currentDeltaDb > 1)
        decreaseButton.frame = NSRect(x: containerWidth - 104, y: 6, width: 24, height: 20)

        let increaseButton = createDeltaButton(title: L("button.increase"), target: target, action: increaseAction, enabled: currentDeltaDb < 6)
        increaseButton.frame = NSRect(x: containerWidth - 38, y: 6, width: 24, height: 20)

        return [valueLabel, decreaseButton, increaseButton]
    }
    
    private static func createDeltaButton(title: String, target: AnyObject, action: Selector, enabled: Bool) -> NSButton {
        let button = NSButton(frame: .zero)
        button.title = title
        button.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        button.bezelStyle = .rounded
        button.controlSize = .mini
        button.target = target
        button.action = action
        button.isEnabled = enabled
        return button
    }
    
    // MARK: - Audio Sources Section
    static func createAudioSourcesSection(state: MiloState?, loadingStates: [String: Bool] = [:], target: AnyObject, action: Selector) -> [NSMenuItem] {
        var items: [NSMenuItem] = []

        items.append(createSecondaryHeader(title: L("menu.audio_sources.title")))

        let activeSource = state?.activeSource ?? "none"
        let isPluginStarting = state?.pluginState.lowercased() == "starting"

        let sourceConfigs = [
            (L("source.spotify"), "music.note", "spotify"),
            (L("source.bluetooth"), "bluetooth", "bluetooth"),
            (L("source.mac"), "desktopcomputer", "mac"),
            (L("source.radio"), "radio", "radio"),
            (L("source.podcast"), "podcasts-icon", "podcast")
        ]

        for (title, iconName, sourceId) in sourceConfigs {
            let isLoading = isPluginStarting && (activeSource == sourceId)
            let isActive = (activeSource == sourceId)

            let config = MenuItemConfig(
                title: title,
                iconName: iconName,
                isActive: isActive,
                target: target,
                action: action,
                representedObject: sourceId
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
    static func createSystemControlsSection(state: MiloState?, loadingStates: [String: Bool] = [:], target: AnyObject, action: Selector) -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        
        items.append(createSecondaryHeader(title: L("menu.features.title")))
        
        let systemConfigs = [
            (L("feature.multiroom"), "speaker.wave.3", "multiroom", state?.multiroomEnabled ?? false),
            (L("feature.equalizer"), "slider.horizontal.3", "equalizer", state?.equalizerEnabled ?? false)
        ]
        
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
    
    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
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
