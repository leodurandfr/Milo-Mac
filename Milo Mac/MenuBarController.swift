import SwiftUI
import AppKit

class MenuBarController: NSObject, MiloConnectionManagerDelegate {
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

    // MARK: - UI State
    private var activeMenu: NSMenu?
    private var isPreferencesMenuActive = false
    private var isRebuildingMenu = false
    
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
        
        guard let event = NSApp.currentEvent else {
            showMainMenu()
            return
        }
        
        if event.modifierFlags.contains(.option) {
            showPreferencesMenu()
        } else {
            showMainMenu()
        }
    }
    
    private func showMainMenu() {
        let menu = createMenu(isPreferences: false)
        displayMenu(menu)
    }
    
    private func showPreferencesMenu() {
        let menu = createMenu(isPreferences: true)
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
        statusItem.menu = menu

        statusItem.button?.performClick(nil)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.statusItem.menu = nil
        }

        // Use notification for reliable menu closure detection
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(menuDidEndTracking),
            name: NSMenu.didEndTrackingNotification,
            object: menu
        )

        if isMiloConnected {
            refreshMenuData(includeDockApps: true)
        }
    }

    @objc private func menuDidEndTracking(_ notification: Notification) {
        guard let menu = notification.object as? NSMenu, menu === activeMenu else { return }
        // Ignore if menu is being rebuilt (removeAllItems can trigger end-tracking)
        if isRebuildingMenu { return }
        NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: menu)
        handleMenuClosed()
    }
    
    private func handleMenuClosed() {
        NSLog("🚪 handleMenuClosed called (was menuOpen=\(isMenuOpen))")
        if let menu = activeMenu {
            NotificationCenter.default.removeObserver(self, name: NSMenu.didEndTrackingNotification, object: menu)
        }
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

            // Ajouter chevron interactif pour ouvrir le submenu radio au hover
            if let sourceId = item.representedObject as? String,
               sourceId == "radio",
               currentState?.activeSource == "radio",
               ["ready", "connected"].contains(currentState?.pluginState.lowercased()),
               cachedRadioFavorites != nil {
                let radioSubmenu = buildRadioSubmenu()

                if let containerView = item.view {
                    let chevronView = RadioChevronView(
                        frame: NSRect(x: 265, y: 0, width: 35, height: 32),
                        submenu: radioSubmenu,
                        menuItem: item
                    )
                    containerView.addSubview(chevronView)
                }

                NSLog("📋 Radio chevron added: \(radioSubmenu.items.count) items")
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
    private func buildRadioSubmenu() -> NSMenu {
        let submenu = NSMenu()

        // Utiliser le cache au lieu de fetch async
        guard let favorites = cachedRadioFavorites, !favorites.isEmpty else {
            NSLog("⚠️ buildRadioSubmenu: cache empty or nil (count: \(cachedRadioFavorites?.count ?? 0))")
            let noFavoritesItem = NSMenuItem(title: L("radio.noFavorites"), action: nil, keyEquivalent: "")
            noFavoritesItem.isEnabled = false
            submenu.addItem(noFavoritesItem)
            return submenu
        }

        NSLog("📋 buildRadioSubmenu: \(favorites.count) stations in cache")

        // Log la structure de la première station pour debug
        if let firstStation = favorites.first {
            NSLog("🔍 Sample station keys: \(Array(firstStation.keys))")
            NSLog("🔍 Sample station: \(firstStation)")
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
        NSLog("📻 buildRadioSubmenu: is_playing=\(metadataIsPlaying), currentStationId=\(currentStationId ?? "nil")")

        var addedCount = 0
        // Add each favorite station (synchrone, pas de Task)
        for station in sortedFavorites {
            guard let stationId = station["id"] as? String,
                  let stationName = station["name"] as? String else {
                NSLog("⚠️ Station skipped - missing keys. Available: \(Array(station.keys))")
                continue
            }

            let isCurrentStation = (stationId == currentStationId)

            // All items use custom views to prevent menu from closing on click
            let stationItem = NSMenuItem()
            let view = RadioStationItemView(
                stationName: stationName,
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
            addedCount += 1
        }

        NSLog("✅ Submenu built: \(addedCount)/\(favorites.count) stations added")
        return submenu
    }

    @objc private func radioStationClicked(_ sender: NSMenuItem) {
        guard let apiService = connectionManager.getAPIService(),
              let info = sender.representedObject as? [String: Any],
              let stationId = info["stationId"] as? String,
              let isPlaying = info["isPlaying"] as? Bool else {
            NSLog("⚠️ radioStationClicked: guard failed, representedObject=\(String(describing: sender.representedObject))")
            return
        }

        NSLog("📻 radioStationClicked: stationId=\(stationId), isPlaying=\(isPlaying)")

        Task {
            do {
                if isPlaying {
                    try await apiService.stopRadioPlayback()
                    NSLog("⏹ Radio stopped")
                } else {
                    try await apiService.playRadioStation(stationId)
                    NSLog("▶️ Radio playing: \(stationId)")
                    if currentState?.activeSource != "radio" {
                        try await apiService.changeSource("radio")
                    }
                }
            } catch {
                NSLog("❌ Error handling radio station click: \(error)")
            }
        }
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
        Task {
            do {
                try await apiService.playRadioStation(stationId)
                NSLog("▶️ Radio playing: \(stationId)")
                if currentState?.activeSource != "radio" {
                    try await apiService.changeSource("radio")
                }
            } catch {
                NSLog("❌ Error playing radio: \(error)")
            }
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
                // En cas d'erreur HTTP, arrêter le loading silencieusement
                await MainActor.run {
                    self.stopFunctionalityLoading(for: toggleType)
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
        
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = Timer.scheduledTimer(withTimeInterval: functionalityLoadingTimeout, repeats: false) { _ in
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
        // Vérifier multiroom
        if let expectedMultiroom = expectedFunctionalityStates["multiroom"],
           newState.multiroomEnabled == expectedMultiroom,
           loadingStates["multiroom"] == true {
            stopFunctionalityLoading(for: "multiroom")
        }

        // Vérifier equalizer (DSP)
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

        let allKnownSources = ["spotify", "bluetooth", "mac", "airplay", "radio", "podcast"]
        let audioSources = enabledDockApps?.filter { allKnownSources.contains($0) } ?? allKnownSources
        let isPluginStarting = state.pluginState.lowercased() == "starting"

        for identifier in audioSources {
            if isPluginStarting && identifier == state.activeSource {
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
        isRebuildingMenu = true
        CircularMenuItem.cleanupAllSpinners()
        menu.removeAllItems()

        if isMiloConnected {
            buildConnectedMenu(menu, isPreferences: isPreferencesMenuActive)
        } else {
            buildDisconnectedMenu(menu, isPreferences: isPreferencesMenuActive)
        }
        isRebuildingMenu = false
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
        NSLog("📬 didReceiveStateUpdate: source=\(state.activeSource), plugin=\(state.pluginState), menuOpen=\(isMenuOpen), activeMenu=\(activeMenu != nil)")
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
            NSLog("🗑️ Radio favorites cache cleared")
        }

        checkFunctionalityStateChange(state)
        syncLoadingStatesWithBackend()

        // Toujours rafraîchir le menu ouvert pour refléter les changements d'état
        if isMenuOpen, let menu = activeMenu {
            updateMenuInRealTime(menu)
        }
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
