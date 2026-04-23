import SwiftUI
import AppKit

class MenuBarController: NSObject, MiloConnectionManagerDelegate, NSMenuDelegate {
    // MARK: - Properties
    private var statusItem: NSStatusItem
    private(set) var connectionManager: MiloConnectionManager!
    private var hotkeyManager: GlobalHotkeyManager?
    private let volumeController = VolumeController()
    
    // MARK: - State
    private var isMiloConnected = false
    private var currentState: MiloState?
    private(set) var currentVolume: VolumeStatus?
    private var isMenuOpen = false

    // MARK: - Dock Apps Cache
    private var enabledDockApps: [String]?

    // MARK: - Radio Cache
    private var cachedRadioFavorites: [[String: Any]]?
    // Persistent submenu instance kept across top-menu rebuilds. Mutating its
    // items (via populateRadioSubmenu) refreshes the visible flyout in place
    // without closing it — a new NSMenu per rebuild would detach the open
    // flyout from the tree and leave it stale.
    private var radioSubmenu: NSMenu?
    // Set while a station play/change is in flight. When non-nil, the Radio
    // row's right-side chevron is replaced by a LoadingSpinner; cleared when
    // the backend broadcasts is_buffering=false (success or failed stream).
    private var radioStationLoadingId: String?
    private var radioStationLoadingTimer: Timer?
    private let radioStationLoadingTimeout: TimeInterval = 15.0

    // MARK: - UI State
    private var activeMenu: NSMenu?
    private var isPreferencesMenuActive = false
    
    // MARK: - Loading State Management
    private var loadingStates: [String: Bool] = [:]
    private var loadingTimers: [String: Timer] = [:]
    private var loadingStartTimes: [String: Date] = [:]
    private var manualLoadingProtection: [String: Date] = [:]
    private var expectedFunctionalityStates: [String: Bool] = [:]
    
    // MARK: - Background Refresh
    private var backgroundRefreshTimer: Timer?
    private var consecutiveRefreshFailures = 0
    private var lastSuccessfulRefresh: Date?

    // MARK: - Constants
    private let loadingTimeoutDuration: TimeInterval = 15.0
    private let functionalityLoadingTimeout: TimeInterval = 10.0
    // Multiroom toggles take longer on the backend (snapserver start,
    // wait_for_ready up to 15s, volume push), so its safety timeout is higher.
    private let multiroomLoadingTimeout: TimeInterval = 35.0
    private let minimumFunctionalityLoadingDuration: TimeInterval = 1.2
    private let maxConsecutiveFailures = 3
    
    // MARK: - Initialization
    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()
        
        setupStatusItem()
        setupConnectionManager()
        setupObservers()
        updateIcon()
    }
    
    private func setupStatusItem() {
        statusItem.button?.image = createCustomIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(menuButtonClicked)
        statusItem.button?.image?.isTemplate = true
    }
    
    private func createCustomIcon() -> NSImage? {
        if let image = NSImage(named: "menubar-icon") {
            image.isTemplate = true
            image.size = NSSize(width: 22, height: 22)
            return image
        }
        
        let fallbackImage = NSImage(systemSymbolName: "speaker.wave.3", accessibilityDescription: L("accessibility.milo_icon"))
        fallbackImage?.isTemplate = true
        return fallbackImage
    }
    
    private func setupConnectionManager() {
        connectionManager = MiloConnectionManager()
        connectionManager.delegate = self
        hotkeyManager = GlobalHotkeyManager(connectionManager: connectionManager, menuController: self)
        connectionManager.start()
    }
    
    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeChangedViaHotkey),
            name: NSNotification.Name("VolumeChangedViaHotkey"),
            object: nil
        )
    }
    
    private func startBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        consecutiveRefreshFailures = 0
        lastSuccessfulRefresh = Date()

        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isMiloConnected, !self.isMenuOpen else { return }

            // Arrêter le refresh si trop d'échecs consécutifs
            if self.consecutiveRefreshFailures >= self.maxConsecutiveFailures {
                NSLog("⚠️ Background refresh paused after \(self.consecutiveRefreshFailures) failures")
                return
            }

            Task {
                // Le volume est mis à jour via WebSocket en temps réel,
                // pas besoin de le poll ici
                async let stateResult = self.refreshState()
                async let dockAppsResult = self.refreshDockApps()

                let stateSuccess = await stateResult
                let _ = await dockAppsResult

                await MainActor.run {
                    if stateSuccess {
                        self.consecutiveRefreshFailures = 0
                        self.lastSuccessfulRefresh = Date()
                    } else {
                        self.consecutiveRefreshFailures += 1
                    }
                }
            }
        }
    }
    
    private func stopBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        backgroundRefreshTimer = nil
    }
    
    // MARK: - Public Interface
    func isMenuCurrentlyOpen() -> Bool {
        return isMenuOpen
    }

    func updateVolumeStatus(_ volumeStatus: VolumeStatus) {
        currentVolume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)
        volumeController.updateVolumeLimits(
            minDb: volumeStatus.limitMinDb,
            maxDb: volumeStatus.limitMaxDb
        )
    }
    
    // MARK: - Menu Display
    @objc private func menuButtonClicked() {
        statusItem.menu = nil

        let isPreferences: Bool
        if let event = NSApp.currentEvent, event.modifierFlags.contains(.option) {
            isPreferences = true
        } else {
            isPreferences = false
        }

        hotkeyManager?.volumeHUD?.hideWithCoreAnimation()
        openMenu(isPreferences: isPreferences)
    }

    private func openMenu(isPreferences: Bool) {
        let menu = createMenu(isPreferences: isPreferences)
        displayMenu(menu)
    }
    
    
    private func createMenu(isPreferences: Bool) -> NSMenu {
        isMenuOpen = true
        
        let menu = NSMenu()
        menu.font = NSFont.menuFont(ofSize: 13)
        
        if isMiloConnected {
            buildConnectedMenu(menu, isPreferences: isPreferences)
        } else {
            buildDisconnectedMenu(menu, isPreferences: isPreferences)
        }
        
        activeMenu = menu
        isPreferencesMenuActive = isPreferences
        volumeController.activeMenu = menu
        
        return menu
    }
    
    private func displayMenu(_ menu: NSMenu) {
        NSApp.activate(ignoringOtherApps: true)
        menu.delegate = self
        statusItem.menu = menu

        statusItem.button?.performClick(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.statusItem.menu = nil
        }

        if isMiloConnected {
            refreshMenuData(includeDockApps: true)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === activeMenu else { return }
        handleMenuClosed()
    }
    
    private func handleMenuClosed() {
        isMenuOpen = false
        volumeController.cleanup()
        activeMenu = nil
        isPreferencesMenuActive = false
        volumeController.activeMenu = nil
    }
    
    // MARK: - Menu Building
    private func buildConnectedMenu(_ menu: NSMenu, isPreferences: Bool) {
        
        addVolumeSection(to: menu)
        addAudioSourcesSection(to: menu)
        addSystemControlsSection(to: menu)
        
        if isPreferences {
            addPreferencesSection(to: menu)
        }
    }
    
    private func buildDisconnectedMenu(_ menu: NSMenu, isPreferences: Bool) {
        let disconnectedItem = MenuItemFactory.createDisconnectedItem()
        menu.addItem(disconnectedItem)
                
        if isPreferences {
            menu.addItem(NSMenuItem.separator())
            addPreferencesSection(to: menu, connected: false)
        }
    }
    
    private func addVolumeSection(to menu: NSMenu) {
        let volumeItems = MenuItemFactory.createVolumeSection(
            volumeDb: currentVolume?.volumeDb ?? -80.0,
            limitMinDb: currentVolume?.limitMinDb ?? -80.0,
            limitMaxDb: currentVolume?.limitMaxDb ?? -21.0,
            target: self,
            action: #selector(volumeChanged)
        )
        volumeItems.forEach { menu.addItem($0) }

        if let sliderItem = volumeItems.first(where: { $0.view is MenuInteractionView }),
           let sliderView = sliderItem.view as? MenuInteractionView,
           let slider = sliderView.subviews.first(where: { $0 is NSSlider }) as? NSSlider {
            volumeController.setVolumeSlider(slider)
        }
    }
    
    private func addAudioSourcesSection(to menu: NSMenu) {
        let sourceItems = MenuItemFactory.createAudioSourcesSection(
            state: currentState,
            loadingStates: loadingStates,
            enabledApps: enabledDockApps,
            target: self,
            action: #selector(sourceClicked)
        )

        // Add items to menu and attach submenu to Radio if favorites available
        for item in sourceItems {
            menu.addItem(item)

            // Attacher le submenu radio : NSMenu ouvre nativement le flyout au hover sur toute la ligne
            if let sourceId = item.representedObject as? String,
               sourceId == "radio",
               currentState?.activeSource == "radio",
               ["waiting", "active"].contains(currentState?.sourceState.lowercased()),
               cachedRadioFavorites != nil {
                // Reuse the persistent NSMenu instance across rebuilds: attaching
                // a new NSMenu each time would orphan an already-displayed flyout
                // and leave its items stale.
                let submenu = radioSubmenu ?? NSMenu()
                radioSubmenu = submenu
                populateRadioSubmenu(submenu)
                item.submenu = submenu

                if let containerView = item.view {
                    if radioStationLoadingId != nil {
                        // A station play/change is in flight: swap the chevron
                        // for a spinner until is_buffering resolves. Match the
                        // chevron's 50% alpha so the indicator blends in at the
                        // same visual weight. Register with CircularMenuItem so
                        // cleanupAllSpinners stops the timer deterministically
                        // on the next menu rebuild instead of relying on ARC.
                        let spinner = LoadingSpinner(frame: NSRect(x: 272, y: 7, width: 18, height: 18))
                        spinner.alphaValue = 0.5
                        containerView.addSubview(spinner)
                        spinner.startAnimating()
                        CircularMenuItem.registerSpinner(spinner)
                    } else if let chevronImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
                        let chevronView = NSImageView(image: chevronImage)
                        chevronView.contentTintColor = NSColor.labelColor.withAlphaComponent(0.5)
                        chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                        chevronView.frame = NSRect(x: 276, y: 10, width: 12, height: 12)
                        containerView.addSubview(chevronView)
                    }
                }

                NSLog("📋 Radio submenu attached: \(submenu.items.count) items, loading=\(radioStationLoadingId != nil)")
            }
        }
    }
    
    private func addSystemControlsSection(to menu: NSMenu) {
        let systemItems = MenuItemFactory.createSystemControlsSection(
            state: currentState,
            loadingStates: loadingStates,
            enabledApps: enabledDockApps,
            target: self,
            action: #selector(toggleClicked)
        )
        systemItems.forEach { menu.addItem($0) }
    }
    
    private func addPreferencesSection(to menu: NSMenu, connected: Bool = true) {
        menu.addItem(NSMenuItem.separator())

        // Settings window item
        let settingsItem = NSMenuItem(
            title: L("config.settings"),
            action: #selector(openSettingsWindow),
            keyEquivalent: ","
        )
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())
        addQuitItem(to: menu)
    }

    @objc private func openSettingsWindow() {
        SettingsWindowController.shared.configure(
            hotkeyManager: hotkeyManager,
            rocVADManager: connectionManager.rocVADManager
        )
        SettingsWindowController.shared.showWindow()
    }

    private func addQuitItem(to menu: NSMenu) {
        let quitItem = MenuItemHelper.createSimpleMenuItem(
            title: L("config.quit"),
            target: self,
            action: #selector(quitApplication)
        )
        menu.addItem(quitItem)
    }

    // MARK: - Radio Submenu
    /// Fills (or refills) the given submenu with current favorites and play
    /// state. When the station set hasn't changed (common case: play/stop a
    /// favorite), mutates the existing RadioStationItemViews in place so the
    /// visible flyout refreshes without AppKit tearing it down. Only falls
    /// back to removeAllItems + re-add when the favorites list itself changes.
    private func populateRadioSubmenu(_ submenu: NSMenu) {
        // No favorites cached yet (or empty): show placeholder.
        guard let favorites = cachedRadioFavorites, !favorites.isEmpty else {
            NSLog("⚠️ populateRadioSubmenu: cache empty or nil (count: \(cachedRadioFavorites?.count ?? 0))")
            submenu.removeAllItems()
            let noFavoritesItem = NSMenuItem(title: L("radio.noFavorites"), action: nil, keyEquivalent: "")
            noFavoritesItem.isEnabled = false
            submenu.addItem(noFavoritesItem)
            return
        }

        // Trier par ordre alphabétique
        let sortedFavorites = favorites.sorted { station1, station2 in
            let name1 = station1["name"] as? String ?? ""
            let name2 = station2["name"] as? String ?? ""
            return name1.localizedCaseInsensitiveCompare(name2) == .orderedAscending
        }

        // Get currently playing station info (use is_playing flag, not just station_id presence)
        let metadataIsPlaying = currentState?.metadata["is_playing"] as? Int == 1
        let currentStationId = (currentState?.activeSource == "radio" && metadataIsPlaying) ?
            currentState?.metadata["station_id"] as? String : nil
        NSLog("📻 populateRadioSubmenu: is_playing=\(metadataIsPlaying), currentStationId=\(currentStationId ?? "nil")")

        // Build the expected (id, name, isCurrent) tuples.
        var expected: [(id: String, name: String, isCurrent: Bool)] = []
        for station in sortedFavorites {
            guard let id = station["id"] as? String,
                  let name = station["name"] as? String else { continue }
            expected.append((id, name, id == currentStationId))
        }

        // If the set of station ids (and order) already matches, update the
        // existing views in place. This is the common case triggered by a
        // play/stop event and is what keeps the open flyout from going stale.
        let existingStationIds: [String] = submenu.items.compactMap {
            ($0.view as? RadioStationItemView)?.stationId
        }
        if existingStationIds == expected.map({ $0.id }) {
            for (index, entry) in expected.enumerated() {
                guard let view = submenu.items[index].view as? RadioStationItemView else { continue }
                let stationId = entry.id
                let isCurrentStation = entry.isCurrent
                view.update(isPlaying: isCurrentStation, clickHandler: { [weak self] in
                    if isCurrentStation {
                        self?.handleRadioStationStop(stationId: stationId)
                    } else {
                        self?.handleRadioStationPlay(stationId: stationId)
                    }
                })
            }
            NSLog("♻️ populateRadioSubmenu: \(expected.count) stations updated in place")
            return
        }

        // Favorites list itself changed (first build, add/remove, rename): full rebuild.
        submenu.removeAllItems()
        for entry in expected {
            let stationId = entry.id
            let isCurrentStation = entry.isCurrent
            let stationItem = NSMenuItem()
            let view = RadioStationItemView(
                stationId: stationId,
                stationName: entry.name,
                isPlaying: isCurrentStation,
                clickHandler: { [weak self] in
                    if isCurrentStation {
                        self?.handleRadioStationStop(stationId: stationId)
                    } else {
                        self?.handleRadioStationPlay(stationId: stationId)
                    }
                }
            )
            stationItem.view = view
            submenu.addItem(stationItem)
        }
        let addedCount = expected.count

        NSLog("✅ Submenu populated: \(addedCount)/\(favorites.count) stations added")
    }

    /// Refresh the visible radio flyout in place if one is currently attached.
    /// Called on state updates so the ⏹/▶ affordances on each station reflect
    /// the backend without closing the menu.
    private func refreshRadioSubmenuInPlace() {
        guard let submenu = radioSubmenu else { return }
        populateRadioSubmenu(submenu)
    }



    private func handleRadioStationStop(stationId: String) {
        guard let apiService = connectionManager.getAPIService() else { return }
        NSLog("📻 handleRadioStationStop: \(stationId)")
        Task {
            do {
                try await apiService.stopRadioPlayback()
                NSLog("⏹ Radio stopped: \(stationId)")
            } catch {
                NSLog("❌ Error stopping radio: \(error)")
            }
        }
    }

    private func handleRadioStationPlay(stationId: String) {
        guard let apiService = connectionManager.getAPIService() else { return }
        NSLog("📻 handleRadioStationPlay: \(stationId)")
        beginRadioStationLoading(stationId: stationId)
        Task {
            do {
                try await apiService.playRadioStation(stationId)
                NSLog("▶️ Radio playing: \(stationId)")
                if currentState?.activeSource != "radio" {
                    try await apiService.changeSource("radio")
                }
            } catch {
                NSLog("❌ Error playing radio: \(error)")
                await MainActor.run { self.endRadioStationLoading() }
            }
        }
    }

    private func beginRadioStationLoading(stationId: String) {
        radioStationLoadingId = stationId
        radioStationLoadingTimer?.invalidate()
        radioStationLoadingTimer = Timer.scheduledTimer(withTimeInterval: radioStationLoadingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                NSLog("⏱️ Radio station loading timeout — clearing spinner")
                self?.endRadioStationLoading()
            }
        }
        // Refresh the menu so the chevron swaps to a spinner immediately if
        // the menu is still open on the next display.
        if let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }

    private func endRadioStationLoading() {
        guard radioStationLoadingId != nil else { return }
        radioStationLoadingId = nil
        radioStationLoadingTimer?.invalidate()
        radioStationLoadingTimer = nil
        if let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }

    private func loadRadioFavoritesInBackground() {
        guard let apiService = connectionManager.getAPIService() else { return }

        Task {
            do {
                let favorites = try await apiService.getRadioFavorites()
                await MainActor.run {
                    cachedRadioFavorites = favorites
                    NSLog("✅ Radio favorites loaded: \(favorites.count) stations")

                    // Rafraîchir le menu si ouvert pour afficher le chevron immédiatement
                    if isMenuOpen, let menu = activeMenu {
                        NSLog("🔄 Refreshing menu to show Radio chevron")
                        updateMenuInRealTime(menu)
                    }
                }
            } catch {
                NSLog("❌ Failed to load radio favorites: \(error)")
                await MainActor.run {
                    cachedRadioFavorites = nil
                }
            }
        }
    }

    // MARK: - Actions
    @objc private func volumeChanged(_ sender: NSSlider) {
        let newVolumeDb = sender.doubleValue
        volumeController.handleVolumeChange(newVolumeDb)
    }
    
    @objc private func sourceClicked(_ sender: NSMenuItem) {
        guard let sourceId = sender.representedObject as? String,
              let apiService = connectionManager.getAPIService(),
              isMiloConnected else { return }
        
        let activeSource = currentState?.activeSource ?? "none"
        guard activeSource != sourceId else { return }
        
        // Éviter les actions pendant les problèmes réseau
        if loadingStates[sourceId] == true {
            return
        }
        
        Task {
            do {
                try await apiService.changeSource(sourceId)
                await MainActor.run {
                    self.startLoading(for: sourceId, timeout: self.loadingTimeoutDuration)
                }
            } catch {
                // Silencieux - pas de log pour les erreurs réseau fréquentes
            }
        }
    }
    
    @objc private func toggleClicked(_ sender: NSMenuItem) {
        guard let toggleType = sender.representedObject as? String,
              let apiService = connectionManager.getAPIService(),
              isMiloConnected else { return }
        
        // Protection contre les actions concurrentes
        if loadingStates[toggleType] == true {
            return
        }
        
        let currentlyEnabled = getCurrentToggleState(toggleType)
        let newState = !currentlyEnabled
        
        // Démarrer le loading avant la requête pour éviter les race conditions
        startFunctionalityLoading(for: toggleType, expectedState: newState)
        
        Task {
            do {
                switch toggleType {
                case "multiroom":
                    try await apiService.setMultiroom(newState)
                case "equalizer":
                    try await apiService.setEqualizer(newState)
                default:
                    await MainActor.run {
                        self.stopFunctionalityLoading(for: toggleType)
                    }
                    return
                }
            } catch {
                // Multiroom: the PUT can still fail spuriously even with the
                // extended timeout while the backend finishes the transition.
                // Keep the spinner — it will resolve on multiroom_changed /
                // multiroom_error via WebSocket, or via the safety timeout.
                // For other toggles, stop immediately.
                if toggleType != "multiroom" {
                    await MainActor.run {
                        self.stopFunctionalityLoading(for: toggleType)
                    }
                } else {
                    NSLog("⚠️ setMultiroom HTTP error (spinner kept until WS signal): \(error)")
                }
            }
        }
    }
    
    @objc private func quitApplication() {
        NSApplication.shared.terminate(nil)
    }
    
    // MARK: - Functionality Loading Management
    private func startFunctionalityLoading(for identifier: String, expectedState: Bool) {
        guard loadingStates[identifier] != true else { return }

        expectedFunctionalityStates[identifier] = expectedState
        loadingStartTimes[identifier] = Date()
        manualLoadingProtection[identifier] = Date()
        setLoadingState(for: identifier, isLoading: true)

        let safetyTimeout = identifier == "multiroom" ? multiroomLoadingTimeout : functionalityLoadingTimeout
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = Timer.scheduledTimer(withTimeInterval: safetyTimeout, repeats: false) { _ in
            Task { @MainActor in self.stopFunctionalityLoading(for: identifier) }
        }
    }
    
    private func stopFunctionalityLoading(for identifier: String) {
        // Respecter la durée minimale d'affichage
        if let startTime = loadingStartTimes[identifier] {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < minimumFunctionalityLoadingDuration {
                let remainingTime = minimumFunctionalityLoadingDuration - elapsed
                DispatchQueue.main.asyncAfter(deadline: .now() + remainingTime) { [weak self] in
                    self?.stopFunctionalityLoading(for: identifier)
                }
                return
            }
        }
        
        setLoadingState(for: identifier, isLoading: false)
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = nil
        loadingStartTimes[identifier] = nil
        manualLoadingProtection[identifier] = nil
        expectedFunctionalityStates[identifier] = nil
        
        if let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }
    
    private func checkFunctionalityStateChange(_ newState: MiloState) {
        // Multiroom loading is resolved via didReceiveMultiroomTransitionComplete,
        // not by matching state here: the backend silently pre-sets
        // multiroom_enabled before the actual routing work (snapserver start,
        // WebSocket readiness up to 15s), so intermediate state broadcasts
        // already carry the new value and would resolve the spinner too early.

        if let expectedEqualizer = expectedFunctionalityStates["equalizer"],
           newState.equalizerEnabled == expectedEqualizer,
           loadingStates["equalizer"] == true {
            stopFunctionalityLoading(for: "equalizer")
        }
    }
    
    // MARK: - Audio Source Loading Management
    private func startLoading(for identifier: String, timeout: TimeInterval) {
        guard loadingStates[identifier] != true else { return }
        
        loadingStartTimes[identifier] = Date()
        manualLoadingProtection[identifier] = Date()
        setLoadingState(for: identifier, isLoading: true)
        
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { _ in
            Task { @MainActor in self.stopLoading(for: identifier) }
        }
    }
    
    private func stopLoading(for identifier: String) {
        setLoadingState(for: identifier, isLoading: false)
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = nil
        loadingStartTimes[identifier] = nil
        manualLoadingProtection[identifier] = nil
        
        if let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }
    
    private func setLoadingState(for identifier: String, isLoading: Bool) {
        guard loadingStates[identifier] != isLoading else { return }
        
        loadingStates[identifier] = isLoading
        
        if let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }
    
    // MARK: - State Synchronization
    private func syncLoadingStatesWithBackend() {
        guard let state = currentState else { return }

        let allKnownSources = MenuItemFactory.allSourceIds
        let audioSources = enabledDockApps?.filter { allKnownSources.contains($0) } ?? allKnownSources
        let isSourceTransitioning = state.sourceState.lowercased() == "starting" || state.transitioning

        for identifier in audioSources {
            if isSourceTransitioning && identifier == state.activeSource {
                if loadingStates[identifier] != true {
                    setLoadingState(for: identifier, isLoading: true)
                }
            } else {
                if loadingStates[identifier] == true {
                    // Respecter la protection manuelle (2s minimum)
                    if let protectionTime = manualLoadingProtection[identifier] {
                        let elapsed = Date().timeIntervalSince(protectionTime)
                        if elapsed < 2.0 {
                            continue
                        }
                    }
                    stopLoading(for: identifier)
                }
            }
        }
    }
    
    // MARK: - Helper Methods
    private func getCurrentToggleState(_ toggleType: String) -> Bool {
        switch toggleType {
        case "multiroom": return currentState?.multiroomEnabled ?? false
        case "equalizer": return currentState?.equalizerEnabled ?? true
        default: return false
        }
    }
    
    private func updateMenuInRealTime(_ menu: NSMenu) {
        CircularMenuItem.cleanupAllSpinners()
        menu.removeAllItems()

        if isMiloConnected {
            buildConnectedMenu(menu, isPreferences: isPreferencesMenuActive)
        } else {
            buildDisconnectedMenu(menu, isPreferences: isPreferencesMenuActive)
        }
    }
    
    private func updateIcon() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.alphaValue = self?.isMiloConnected == true ? 1.0 : 0.5
        }
    }
    
    // MARK: - Data Refresh
    private func refreshMenuData(includeDockApps: Bool = false) {
        Task {
            // Si échecs consécutifs détectés, forcer un reset de session
            if consecutiveRefreshFailures >= maxConsecutiveFailures {
                NSLog("🔄 Forcing API session reset due to persistent failures")
                connectionManager.getAPIService()?.resetSession()
                consecutiveRefreshFailures = 0
            }

            // Retry avec timeout plus court pour le menu
            var attempts = 0
            let maxAttempts = 2

            while attempts < maxAttempts {
                // Lancer tous les fetches en parallèle
                async let stateResult = refreshState()
                async let volumeResult = refreshVolumeStatus()
                async let dockAppsResult = includeDockApps ? refreshDockApps() : true

                let stateSuccess = await stateResult
                let volumeSuccess = await volumeResult
                let _ = await dockAppsResult

                if stateSuccess || volumeSuccess {
                    await MainActor.run {
                        consecutiveRefreshFailures = 0
                        lastSuccessfulRefresh = Date()

                        if let menu = self.activeMenu {
                            self.updateMenuInRealTime(menu)
                        }
                    }
                    return
                }

                attempts += 1
                if attempts < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 0.5s entre les tentatives
                }
            }

            // Échec après toutes les tentatives
            await MainActor.run {
                consecutiveRefreshFailures += 1
                NSLog("⚠️ Menu refresh failed after \(maxAttempts) attempts")

                if let menu = self.activeMenu {
                    self.updateMenuInRealTime(menu)
                }
            }
        }
    }
    
    @discardableResult
    private func refreshState() async -> Bool {
        guard let apiService = connectionManager.getAPIService() else { return false }

        do {
            let state = try await apiService.fetchState()
            await MainActor.run {
                self.currentState = state
                // Load radio favorites if radio is already active on connect
                if state.activeSource == "radio" && self.cachedRadioFavorites == nil {
                    self.loadRadioFavoritesInBackground()
                }
            }
            return true
        } catch {
            // Échec silencieux
            return false
        }
    }

    @discardableResult
    private func refreshDockApps() async -> Bool {
        guard let apiService = connectionManager.getAPIService() else { return false }

        do {
            let apps = try await apiService.fetchDockApps()
            await MainActor.run { self.enabledDockApps = apps }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func refreshVolumeStatus() async -> Bool {
        guard let apiService = connectionManager.getAPIService() else { return false }

        do {
            let volumeStatus = try await apiService.getVolumeStatus()
            await MainActor.run {
                let oldVolumeDb = self.currentVolume?.volumeDb ?? -999.0
                self.currentVolume = volumeStatus
                self.volumeController.setCurrentVolume(volumeStatus)
                self.volumeController.updateVolumeLimits(
                    minDb: volumeStatus.limitMinDb,
                    maxDb: volumeStatus.limitMaxDb
                )

                if abs(oldVolumeDb - volumeStatus.volumeDb) > 0.1 {
                    self.volumeController.updateSliderFromWebSocket(volumeStatus.volumeDb)
                }
            }
            return true
        } catch {
            return false
        }
    }
    
    @objc private func handleVolumeChangedViaHotkey(_ notification: Notification) {
        guard let volumeStatus = notification.object as? VolumeStatus else { return }
        let duration = notification.userInfo?["animationDuration"] as? TimeInterval

        currentVolume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)
        volumeController.updateSliderFromWebSocket(volumeStatus.volumeDb, animated: false, duration: duration)
    }
}

// MARK: - MiloConnectionManagerDelegate
extension MenuBarController {
    
    
    func miloDidConnect() {
        isMiloConnected = true
        updateIcon()

        if let apiService = connectionManager.getAPIService() {
            volumeController.apiService = apiService
        }

        // Reset failure counters on successful connection
        consecutiveRefreshFailures = 0
        lastSuccessfulRefresh = Date()

        hotkeyManager?.startMonitoring()
        startBackgroundRefresh()
        refreshMenuData(includeDockApps: true)
    }
    
    func miloDidDisconnect() {
        hotkeyManager?.stopMonitoring()
        stopBackgroundRefresh()
        
        isMiloConnected = false
        updateIcon()
        
        clearState()
        volumeController.cleanup()
        
        if let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }
    
    func didReceiveStateUpdate(_ state: MiloState) {
        NSLog("📬 didReceiveStateUpdate: source=\(state.activeSource), sourceState=\(state.sourceState), transitioning=\(state.transitioning), menuOpen=\(isMenuOpen), activeMenu=\(activeMenu != nil)")
        let previousSource = currentState?.activeSource
        currentState = state

        // Charger favoris si Radio est actif et que le cache est vide
        // (que Radio ait été activé depuis Milo Mac ou depuis le backend)
        if state.activeSource == "radio" && cachedRadioFavorites == nil {
            loadRadioFavoritesInBackground()
        }

        // Effacer cache si on quitte Radio
        if state.activeSource != "radio" && previousSource == "radio" {
            cachedRadioFavorites = nil
            radioSubmenu = nil
            NSLog("🗑️ Radio favorites cache cleared")
        }

        // Clear the chevron→spinner swap as soon as buffering ends — covers
        // both successful playback start and stream-load failures, so the
        // spinner never gets stuck. Also clear if radio stops being active.
        if radioStationLoadingId != nil {
            if state.activeSource != "radio" {
                radioStationLoadingId = nil
                radioStationLoadingTimer?.invalidate()
                radioStationLoadingTimer = nil
            } else {
                let isBuffering = state.metadata["is_buffering"] as? Int == 1
                if !isBuffering {
                    NSLog("✅ Radio station loading cleared (is_buffering=false)")
                    radioStationLoadingId = nil
                    radioStationLoadingTimer?.invalidate()
                    radioStationLoadingTimer = nil
                }
            }
        }

        checkFunctionalityStateChange(state)
        syncLoadingStatesWithBackend()

        // Toujours rafraîchir le menu ouvert pour refléter les changements d'état
        if isMenuOpen, let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
    }
    
    func didReceiveMultiroomTransitionComplete(success: Bool) {
        guard loadingStates["multiroom"] == true else { return }
        if !success {
            // Clear expected state on failure so no late state_changed accidentally
            // re-resolves via any future code path.
            expectedFunctionalityStates["multiroom"] = nil
        }
        stopFunctionalityLoading(for: "multiroom")
    }

    func didReceiveVolumeUpdate(_ volume: VolumeStatus) {
        // WebSocket volume events don't include limits.
        // Preserve the API-sourced limits from the previous currentVolume.
        if let existing = currentVolume {
            currentVolume = VolumeStatus(
                volumeDb: volume.volumeDb,
                multiroomEnabled: volume.multiroomEnabled,
                dspAvailable: volume.dspAvailable,
                limitMinDb: existing.limitMinDb,
                limitMaxDb: existing.limitMaxDb,
                stepMobileDb: volume.stepMobileDb
            )
        } else {
            currentVolume = volume
        }
        volumeController.setCurrentVolume(currentVolume!)

        // Show VolumeHUD on volume changes if setting enabled
        // Skip when menu is open (user is adjusting via the slider)
        if UserDefaults.standard.bool(forKey: "ShowVolumeHUDOnAllChanges"),
           hotkeyManager?.isActivelyAdjusting != true,
           !isMenuOpen,
           let vol = currentVolume {
            hotkeyManager?.volumeHUD?.updateLimits(minDb: vol.limitMinDb, maxDb: vol.limitMaxDb)
            hotkeyManager?.volumeHUD?.show(volumeDb: vol.volumeDb)
        }

        // Skip slider update during active hotkey use to avoid tug-of-war
        // between local prediction (accurate) and lagging server state
        if hotkeyManager?.isActivelyAdjusting == true {
            return
        }
        volumeController.updateSliderFromWebSocket(volume.volumeDb)
    }
    
    private func clearState() {
        currentState = nil
        currentVolume = nil
        enabledDockApps = nil
        volumeController.apiService = nil

        loadingStates.keys.forEach { stopLoading(for: $0) }
        manualLoadingProtection.removeAll()
        expectedFunctionalityStates.removeAll()
    }
}
