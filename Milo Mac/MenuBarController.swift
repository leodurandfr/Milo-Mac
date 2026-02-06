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
    private var currentVolume: VolumeStatus?
    private var isMenuOpen = false

    // MARK: - Radio Cache
    private var cachedRadioFavorites: [[String: Any]]?

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
                let stateSuccess = await self.refreshState()

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
            self?.monitorMenuClosure()
        }
        
        if isMiloConnected {
            refreshMenuData()
        }
    }
    
    private func monitorMenuClosure() {
        if let menu = activeMenu, menu.highlightedItem == nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                if self?.activeMenu?.highlightedItem == nil {
                    self?.handleMenuClosed()
                }
            }
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.monitorMenuClosure()
            }
        }
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
            volumeDb: currentVolume?.volumeDb ?? -30.0,
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
            target: self,
            action: #selector(sourceClicked)
        )

        // Add items to menu and attach submenu to Radio if favorites available
        for item in sourceItems {
            menu.addItem(item)

            // Attacher submenu directement au Radio item si favoris disponibles
            if let sourceId = item.representedObject as? String,
               sourceId == "radio",
               currentState?.activeSource == "radio",
               cachedRadioFavorites != nil {
                item.submenu = buildRadioSubmenu()

                // Ajouter chevron visuel à la vue personnalisée (SF Symbol)
                if let containerView = item.view,
                   let chevronImage = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil) {
                    let chevronView = NSImageView(image: chevronImage)
                    chevronView.contentTintColor = NSColor.secondaryLabelColor
                    chevronView.frame = NSRect(x: 275, y: 10, width: 12, height: 12)
                    chevronView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .medium)
                    containerView.addSubview(chevronView)
                }

                NSLog("📋 Radio submenu attached: \(item.submenu?.items.count ?? 0) items")
            }
        }
    }
    
    private func addSystemControlsSection(to menu: NSMenu) {
        let systemItems = MenuItemFactory.createSystemControlsSection(
            state: currentState,
            loadingStates: loadingStates,
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

        // Get currently playing station info
        let currentStationId = (currentState?.activeSource == "radio") ?
            currentState?.metadata["station_id"] as? String : nil

        var addedCount = 0
        // Add each favorite station (synchrone, pas de Task)
        for station in sortedFavorites {
            guard let stationId = station["id"] as? String,
                  let stationName = station["name"] as? String else {
                NSLog("⚠️ Station skipped - missing keys. Available: \(Array(station.keys))")
                continue
            }

            let isCurrentStation = (stationId == currentStationId)
            let title = isCurrentStation ? "● \(stationName) ⏹" : stationName

            let stationItem = NSMenuItem(
                title: title,
                action: #selector(radioStationClicked(_:)),
                keyEquivalent: ""
            )
            stationItem.target = self
            stationItem.representedObject = ["stationId": stationId, "isPlaying": isCurrentStation]

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
            return
        }

        Task {
            do {
                if isPlaying {
                    // Stop playback
                    try await apiService.stopRadioPlayback()
                } else {
                    // Play the selected station
                    try await apiService.playRadioStation(stationId)
                    // Switch to radio source if not already active
                    if currentState?.activeSource != "radio" {
                        try await apiService.changeSource("radio")
                    }
                }
            } catch {
                NSLog("❌ Error handling radio station click: \(error)")
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
        
        // Vérifier equalizer
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

        let audioSources = ["spotify", "bluetooth", "mac", "radio", "podcast"]
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
        case "equalizer": return currentState?.equalizerEnabled ?? false
        default: return false
        }
    }
    
    private func updateMenuInRealTime(_ menu: NSMenu) {
        // Éviter les refreshs pendant les problèmes réseau
        guard isMiloConnected else { return }
        
        CircularMenuItem.cleanupAllSpinners()
        menu.removeAllItems()
        
        buildConnectedMenu(menu, isPreferences: isPreferencesMenuActive)
    }
    
    private func updateIcon() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.alphaValue = self?.isMiloConnected == true ? 1.0 : 0.5
        }
    }
    
    // MARK: - Data Refresh
    private func refreshMenuData() {
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
                let stateSuccess = await refreshState()
                let volumeSuccess = await refreshVolumeStatus()

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
            await MainActor.run { self.currentState = state }
            return true
        } catch {
            // Échec silencieux
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

        currentVolume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)
        volumeController.updateSliderFromWebSocket(volumeStatus.volumeDb)
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
        refreshMenuData()
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
    }
    
    func didReceiveVolumeUpdate(_ volume: VolumeStatus) {
        currentVolume = volume
        volumeController.setCurrentVolume(volume)
        volumeController.updateSliderFromWebSocket(volume.volumeDb)
    }
    
    private func clearState() {
        currentState = nil
        currentVolume = nil
        volumeController.apiService = nil
        
        loadingStates.keys.forEach { stopLoading(for: $0) }
        manualLoadingProtection.removeAll()
        expectedFunctionalityStates.removeAll()
    }
}
