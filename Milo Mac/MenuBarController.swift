import SwiftUI
import AppKit

class MenuBarController: NSObject, MiloConnectionManagerDelegate, NSMenuDelegate {
    // MARK: - Properties
    private let statusItem: NSStatusItem
    let connectionManager = MiloConnectionManager()
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
    private var cachedRadioFavorites: [RadioStation]?
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
    private var menuRefreshScheduled = false

    // MARK: - Loading State Management
    private var loadingStates: [String: Bool] = [:]
    private var loadingTimers: [String: Timer] = [:]
    private var loadingStartTimes: [String: Date] = [:]
    private var manualLoadingProtection: [String: Date] = [:]
    private var expectedFunctionalityStates: [String: Bool] = [:]

    // MARK: - Background Refresh
    private var backgroundRefreshTimer: Timer?
    private var consecutiveRefreshFailures = 0
    private var refreshPausedUntil: Date?

    // MARK: - Constants
    private let loadingTimeoutDuration: TimeInterval = 15.0
    private let functionalityLoadingTimeout: TimeInterval = 10.0
    // Multiroom toggles take longer on the backend (snapserver start,
    // wait_for_ready up to 15s, volume push), so its safety timeout is higher.
    private let multiroomLoadingTimeout: TimeInterval = 35.0
    private let minimumFunctionalityLoadingDuration: TimeInterval = 1.2
    // Fenêtre de grâce après un clic source : le temps que le backend prenne en
    // charge la transition (transition_start). Tant qu'elle court et que le
    // backend n'a pas encore confirmé, un état "non transitoire" est interprété
    // comme l'ancien état (race clic↔transition_start) et le spinner est gardé.
    // Une fois la transition prise en charge, on n'attend plus ce délai : le
    // spinner s'efface dès la fin de transition (comme le frontend web).
    private let manualLoadingGraceDuration: TimeInterval = 2.0
    private let maxConsecutiveFailures = 3
    // Le WebSocket pousse tous les changements d'état en temps réel : ce poll
    // n'est qu'un filet de sécurité lent pour rattraper un événement manqué.
    private let backgroundRefreshInterval: TimeInterval = 30.0
    private let refreshPauseDuration: TimeInterval = 60.0

    // MARK: - Initialization
    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        super.init()

        setupStatusItem()
        connectionManager.delegate = self
        hotkeyManager = GlobalHotkeyManager(connectionManager: connectionManager, menuController: self)
        setupObservers()
        updateIcon()
        connectionManager.start()
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

    private func setupObservers() {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeChangedViaHotkey),
            name: .volumeChangedViaHotkey,
            object: nil
        )
    }

    private func startBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        consecutiveRefreshFailures = 0
        refreshPausedUntil = nil

        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: backgroundRefreshInterval, repeats: true) { [weak self] _ in
            guard let self = self, self.isMiloConnected, !self.isMenuOpen else { return }

            // Pause auto-récupérante : après trop d'échecs consécutifs on
            // attend refreshPauseDuration puis on retente, au lieu de
            // s'arrêter définitivement jusqu'à la prochaine reconnexion.
            if let pausedUntil = self.refreshPausedUntil {
                guard Date() >= pausedUntil else { return }
                self.refreshPausedUntil = nil
                self.consecutiveRefreshFailures = 0
            }

            // Capturer le service sur le main thread : la propriété est
            // possédée par lui et nillée à la déconnexion.
            guard let apiService = self.connectionManager.apiService else { return }

            Task {
                // Le volume est mis à jour via WebSocket en temps réel, pas besoin
                // de le poll ici. Les réglages statiques (dock apps + limites) sont
                // chargés une fois à la connexion puis poussés par WebSocket.
                let stateSuccess = await self.refreshState(using: apiService)

                await MainActor.run {
                    if stateSuccess {
                        self.consecutiveRefreshFailures = 0
                    } else {
                        self.consecutiveRefreshFailures += 1
                        if self.consecutiveRefreshFailures >= self.maxConsecutiveFailures {
                            NSLog("⚠️ Background refresh paused after %d failures", self.consecutiveRefreshFailures)
                            self.refreshPausedUntil = Date().addingTimeInterval(self.refreshPauseDuration)
                        }
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
            // Les réglages bulk (limites + dock apps) sont fetchés une fois par
            // connexion puis tenus à jour par WebSocket — pas de re-pull ici.
            refreshMenuData()
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard menu === activeMenu else { return }
        handleMenuClosed()
    }

    private func handleMenuClosed() {
        isMenuOpen = false
        // Stopper les timers d'animation des spinners du menu fermé : sinon ils
        // continuent de tourner (~6 ticks/s) sur des vues invisibles jusqu'à la
        // prochaine ouverture.
        CircularMenuItem.cleanupAllSpinners()
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
            addPreferencesSection(to: menu)
        }
    }

    private func addVolumeSection(to menu: NSMenu) {
        let volumeItems = MenuItemFactory.createVolumeSection(
            volumeDb: currentVolume?.volumeDb ?? VolumeDefaults.limitMinDb,
            limitMinDb: currentVolume?.limitMinDb ?? VolumeDefaults.limitMinDb,
            limitMaxDb: currentVolume?.limitMaxDb ?? VolumeDefaults.limitMaxDb,
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
            action: #selector(sourceClicked),
            longPressAction: #selector(sourceHoldToClose)
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

    private func addPreferencesSection(to menu: NSMenu) {
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
            submenu.removeAllItems()
            let noFavoritesItem = NSMenuItem(title: L("radio.noFavorites"), action: nil, keyEquivalent: "")
            noFavoritesItem.isEnabled = false
            submenu.addItem(noFavoritesItem)
            return
        }

        // Trier par ordre alphabétique
        let sortedFavorites = favorites.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }

        // Get currently playing station info (use is_playing flag, not just station_id presence)
        let metadataIsPlaying = currentState?.metadata["is_playing"] as? Int == 1
        let currentStationId = (currentState?.activeSource == "radio" && metadataIsPlaying) ?
            currentState?.metadata["station_id"] as? String : nil

        // Build the expected (id, name, isCurrent) tuples.
        let expected: [(id: String, name: String, isCurrent: Bool)] = sortedFavorites.map {
            ($0.id, $0.name, $0.id == currentStationId)
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
    }

    private func handleRadioStationStop(stationId: String) {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 handleRadioStationStop: %@", stationId)
        Task {
            do {
                try await apiService.stopRadioPlayback()
                NSLog("⏹ Radio stopped: %@", stationId)
            } catch {
                NSLog("❌ Error stopping radio: %@", error.localizedDescription)
            }
        }
    }

    private func handleRadioStationPlay(stationId: String) {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 handleRadioStationPlay: %@", stationId)
        beginRadioStationLoading(stationId: stationId)
        // Lire l'état sur le main thread (il y est possédé) plutôt que dans la
        // Task : la valeur pertinente est celle qu'a vue l'utilisateur au clic.
        let needsSourceSwitch = currentState?.activeSource != "radio"
        Task {
            do {
                try await apiService.playRadioStation(stationId)
                NSLog("▶️ Radio playing: %@", stationId)
                if needsSourceSwitch {
                    try await apiService.changeSource("radio")
                }
            } catch {
                NSLog("❌ Error playing radio: %@", error.localizedDescription)
                await MainActor.run { self.endRadioStationLoading() }
            }
        }
    }

    private func beginRadioStationLoading(stationId: String) {
        radioStationLoadingId = stationId
        radioStationLoadingTimer?.invalidate()
        // Mode .common : le timeout doit pouvoir tomber pendant que le menu est
        // ouvert (le tracking NSMenu suspend les timers du mode par défaut).
        let timer = Timer(timeInterval: radioStationLoadingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                NSLog("⏱️ Radio station loading timeout — clearing spinner")
                self?.endRadioStationLoading()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        radioStationLoadingTimer = timer
        // Refresh the menu so the chevron swaps to a spinner immediately if
        // the menu is still open on the next display.
        scheduleMenuRefresh()
    }

    private func endRadioStationLoading() {
        guard radioStationLoadingId != nil else { return }
        radioStationLoadingId = nil
        radioStationLoadingTimer?.invalidate()
        radioStationLoadingTimer = nil
        scheduleMenuRefresh()
    }

    private func loadRadioFavoritesInBackground() {
        guard let apiService = connectionManager.apiService else { return }

        Task {
            do {
                let favorites = try await apiService.getRadioFavorites()
                await MainActor.run {
                    cachedRadioFavorites = favorites
                    NSLog("✅ Radio favorites loaded: %d stations", favorites.count)

                    // Rafraîchir le menu si ouvert pour afficher le chevron immédiatement
                    scheduleMenuRefresh()
                }
            } catch {
                NSLog("❌ Failed to load radio favorites: %@", error.localizedDescription)
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
              let apiService = connectionManager.apiService,
              isMiloConnected else { return }

        let activeSource = currentState?.activeSource ?? "none"
        guard activeSource != sourceId else { return }

        // Éviter les actions concurrentes pendant qu'une requête est en vol
        if loadingStates[sourceId] == true {
            return
        }

        // Démarrer le loading AVANT la requête (même protocole que
        // toggleClicked) : spinner immédiat et anti double-clic pendant les
        // ~3 s que peut durer le POST.
        startLoading(for: sourceId, timeout: loadingTimeoutDuration)

        Task {
            do {
                try await apiService.changeSource(sourceId)
            } catch {
                // Échec HTTP ou {"status": "error"} in-band : pas de transition
                // à attendre, on arrête le spinner tout de suite.
                NSLog("❌ Source change to %@ failed: %@", sourceId, error.localizedDescription)
                await MainActor.run {
                    self.stopLoading(for: sourceId)
                }
            }
        }
    }

    /// Appui maintenu sur la source active : la ferme (retour à `none`), comme
    /// le hold sur le dock du frontend web.
    @objc private func sourceHoldToClose(_ sender: NSMenuItem) {
        guard let sourceId = sender.representedObject as? String,
              let apiService = connectionManager.apiService,
              isMiloConnected else { return }

        // L'état a pu changer pendant les 500 ms d'appui : ne fermer que si la
        // source visée est toujours l'active, et qu'aucune requête n'est en vol.
        guard currentState?.activeSource == sourceId,
              loadingStates[sourceId] != true else { return }

        // Pas de startLoading ici, contrairement à sourceClicked : la fermeture
        // n'a pas de phase de démarrage côté backend (juste plugin.stop()), et
        // surtout syncLoadingStatesWithBackend ne saurait pas résoudre ce
        // spinner — sa branche « transition confirmée » teste
        // `identifier == activeSource`, or activeSource devient "none". Le
        // spinner tiendrait donc la fenêtre de grâce entière (2 s), pastille
        // peinte en couleur d'accent (loadingIsActive), c'est-à-dire le langage
        // visuel du démarrage. Le broadcast d'état suffit : toutes les pastilles
        // passent au gris. Même choix que le frontend web (onCloseActive).
        Task {
            do {
                try await apiService.changeSource("none")
            } catch {
                NSLog("❌ Closing source %@ failed: %@", sourceId, error.localizedDescription)
                await MainActor.run {
                    // Aucun état à défaire, mais la ligne est restée atténuée par
                    // le geste : la reconstruire lui rend son opacité.
                    self.scheduleMenuRefresh()
                }
            }
        }
    }

    @objc private func toggleClicked(_ sender: NSMenuItem) {
        guard let toggleType = sender.representedObject as? String,
              let apiService = connectionManager.apiService,
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
                    NSLog("⚠️ setMultiroom HTTP error (spinner kept until WS signal): %@", error.localizedDescription)
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
        // Mode .common : le timeout de sécurité est la résolution de dernier
        // recours du spinner — il doit tomber même pendant le tracking du menu.
        let timer = Timer(timeInterval: safetyTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopFunctionalityLoading(for: identifier) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingTimers[identifier] = timer
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

        scheduleMenuRefresh()
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
        // Mode .common — voir startFunctionalityLoading.
        let timer = Timer(timeInterval: timeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopLoading(for: identifier) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingTimers[identifier] = timer
    }

    private func stopLoading(for identifier: String) {
        setLoadingState(for: identifier, isLoading: false)
        loadingTimers[identifier]?.invalidate()
        loadingTimers[identifier] = nil
        loadingStartTimes[identifier] = nil
        manualLoadingProtection[identifier] = nil

        scheduleMenuRefresh()
    }

    private func setLoadingState(for identifier: String, isLoading: Bool) {
        guard loadingStates[identifier] != isLoading else { return }

        loadingStates[identifier] = isLoading

        scheduleMenuRefresh()
    }

    // MARK: - State Synchronization
    private func syncLoadingStatesWithBackend() {
        guard let state = currentState else { return }

        let allKnownSources = MenuItemFactory.allSourceIds
        let audioSources = enabledDockApps?.filter { allKnownSources.contains($0) } ?? allKnownSources
        let isSourceTransitioning = state.sourceState.lowercased() == "starting" || state.transitioning

        for identifier in audioSources {
            if isSourceTransitioning && identifier == state.activeSource {
                // Le backend a pris en charge la transition de cette source.
                if loadingStates[identifier] != true {
                    setLoadingState(for: identifier, isLoading: true)
                }
                // Transition confirmée : on lève la fenêtre de grâce anti-race
                // pour pouvoir effacer le spinner DÈS la fin de transition
                // (comme le frontend web), sans attendre un délai fixe.
                manualLoadingProtection[identifier] = nil
            } else if loadingStates[identifier] == true {
                if let graceStart = manualLoadingProtection[identifier] {
                    // Le backend n'a pas encore confirmé la transition : cet état
                    // "non transitoire" est sans doute l'ancien (race entre le
                    // clic et le transition_start). On garde le spinner jusqu'à
                    // la fin de la fenêtre de grâce, puis on réévalue — sinon, si
                    // le backend n'émet plus rien (source settled en WAITING), le
                    // spinner resterait collé jusqu'au timeout de sécurité (15s).
                    let elapsed = Date().timeIntervalSince(graceStart)
                    if elapsed < manualLoadingGraceDuration {
                        scheduleGraceWindowSourceLoadingClear(identifier, after: manualLoadingGraceDuration - elapsed)
                        continue
                    }
                }
                // Transition confirmée puis terminée (grâce levée), ou fenêtre de
                // grâce expirée sans confirmation : on efface.
                stopLoading(for: identifier)
            }
        }
    }

    /// Réévalue le spinner d'une source à la fin de sa fenêtre de grâce quand le
    /// backend n'a pas encore confirmé la transition, en re-vérifiant l'état
    /// courant (pour ne pas effacer une transition finalement prise en charge).
    private func scheduleGraceWindowSourceLoadingClear(_ identifier: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.loadingStates[identifier] == true, let state = self.currentState else { return }
            let stillTransitioning = (state.sourceState.lowercased() == "starting" || state.transitioning)
                && identifier == state.activeSource
            if !stillTransitioning {
                self.stopLoading(for: identifier)
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

    // MARK: - Menu Refresh (coalesced)

    /// Demande un rebuild du menu ouvert. Les demandes d'un même tour de run
    /// loop sont coalescées : un seul événement WebSocket peut en déclencher
    /// plusieurs (sync des loadings + refresh d'état), et chaque rebuild
    /// recrée slider, tracking areas et spinners — inutile de le faire 4 fois.
    private func scheduleMenuRefresh() {
        guard activeMenu != nil, !menuRefreshScheduled else { return }
        menuRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            self?.flushMenuRefresh()
        }
    }

    private func flushMenuRefresh() {
        menuRefreshScheduled = false
        guard let menu = activeMenu else { return }

        // Ne pas détruire le slider pendant que l'utilisateur le manipule :
        // le rebuild le remplacerait par l'écho (retardé) du serveur et
        // casserait le drag en cours. On retente après le timeout d'interaction.
        if volumeController.isUserInteracting {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.scheduleMenuRefresh()
            }
            return
        }

        // Idem pendant un appui maintenu sur la source active : le rebuild
        // détruirait la vue en plein geste et l'annulerait. Le plafond de 1 s
        // rend le garde auto-cicatrisant si un relâchement était manqué.
        if let pressStart = HoverableView.activePressStartedAt,
           Date().timeIntervalSince(pressStart) < 1.0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                self?.scheduleMenuRefresh()
            }
            return
        }

        updateMenuInRealTime(menu)
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
    /// Rafraîchit état + volume (le menu vient d'être ouvert). Le service est
    /// capturé sur le main thread avant la Task — il est nillé par lui à la
    /// déconnexion, le lire depuis le pool serait une data race.
    private func refreshMenuData() {
        guard let apiService = connectionManager.apiService else { return }

        // Si échecs consécutifs détectés, forcer un reset de session
        if consecutiveRefreshFailures >= maxConsecutiveFailures {
            NSLog("🔄 Forcing API session reset due to persistent failures")
            apiService.resetSession()
            consecutiveRefreshFailures = 0
        }

        Task {
            // Retry avec timeout plus court pour le menu
            var attempts = 0
            let maxAttempts = 2

            while attempts < maxAttempts {
                // Lancer tous les fetches en parallèle
                async let stateResult = refreshState(using: apiService)
                async let volumeResult = refreshVolumeStatus(using: apiService)

                let stateSuccess = await stateResult
                let volumeSuccess = await volumeResult

                if stateSuccess || volumeSuccess {
                    await MainActor.run {
                        self.consecutiveRefreshFailures = 0
                        self.scheduleMenuRefresh()
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
                self.consecutiveRefreshFailures += 1
                NSLog("⚠️ Menu refresh failed after %d attempts", maxAttempts)
                self.scheduleMenuRefresh()
            }
        }
    }

    @discardableResult
    private func refreshState(using apiService: MiloAPIService) async -> Bool {
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

    /// Récupère les réglages statiques (dock apps + limites volume) via /api/settings/bulk.
    /// Met à jour la liste des apps du dock et, par effet de bord côté MiloAPIService,
    /// amorce le cache de limites lu par getVolumeStatus().
    @discardableResult
    private func refreshBulkSettings(using apiService: MiloAPIService) async -> Bool {
        do {
            let settings = try await apiService.fetchBulkSettings()
            await MainActor.run { self.enabledDockApps = settings.enabledApps }
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    private func refreshVolumeStatus(using apiService: MiloAPIService) async -> Bool {
        do {
            let volumeStatus = try await apiService.getVolumeStatus()
            await MainActor.run {
                let oldVolumeDb = self.currentVolume?.volumeDb ?? -999.0
                self.updateVolumeStatus(volumeStatus)

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

        let apiService = connectionManager.apiService
        volumeController.apiService = apiService

        // Reset failure counters on successful connection
        consecutiveRefreshFailures = 0
        refreshPausedUntil = nil

        hotkeyManager?.startMonitoring()
        startBackgroundRefresh()

        // Amorcer le cache des réglages statiques (limites volume + dock apps) via
        // /api/settings/bulk AVANT le premier refresh volume : getVolumeStatus() lit
        // les limites en cache, donc ce fetch doit atterrir d'abord pour éviter une
        // fenêtre où le HUD afficherait les limites par défaut (-80/-21).
        guard let apiService else { return }
        Task { [weak self] in
            guard let self else { return }
            await self.refreshBulkSettings(using: apiService)
            await MainActor.run { self.refreshMenuData() }
        }
    }

    func miloDidDisconnect() {
        hotkeyManager?.stopMonitoring()
        stopBackgroundRefresh()

        isMiloConnected = false
        updateIcon()

        clearState()
        volumeController.cleanup()

        scheduleMenuRefresh()
    }

    func didReceiveStateUpdate(_ state: MiloState) {
        NSLog("📬 didReceiveStateUpdate: source=%@, sourceState=%@, transitioning=%d, menuOpen=%d", state.activeSource, state.sourceState, state.transitioning ? 1 : 0, isMenuOpen ? 1 : 0)
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
                endRadioStationLoading()
            } else if state.metadata["is_buffering"] as? Int != 1 {
                NSLog("✅ Radio station loading cleared (is_buffering=false)")
                endRadioStationLoading()
            }
        }

        checkFunctionalityStateChange(state)
        syncLoadingStatesWithBackend()

        // Toujours rafraîchir le menu ouvert pour refléter les changements d'état
        scheduleMenuRefresh()
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
        // WebSocket volume events don't include limits (the service sends 0/0).
        // Always substitute the cached limits — storing 0/0 would brick the
        // slider (empty range), notably in the window between connect and the
        // first volume fetch where currentVolume is still nil.
        let fallback = (minDb: VolumeDefaults.limitMinDb, maxDb: VolumeDefaults.limitMaxDb)
        let cached = connectionManager.apiService?.cachedLimits ?? fallback
        let limits = currentVolume.map { (minDb: $0.limitMinDb, maxDb: $0.limitMaxDb) } ?? cached
        let updated = volume.withLimits(minDb: limits.minDb, maxDb: limits.maxDb)

        currentVolume = updated
        volumeController.setCurrentVolume(updated)

        // Show VolumeHUD on volume changes if setting enabled
        // Skip when menu is open (user is adjusting via the slider)
        if UserDefaults.standard.bool(forKey: DefaultsKey.showVolumeHUDOnAllChanges),
           hotkeyManager?.isActivelyAdjusting != true,
           !isMenuOpen {
            hotkeyManager?.volumeHUD?.updateLimits(minDb: updated.limitMinDb, maxDb: updated.limitMaxDb)
            hotkeyManager?.volumeHUD?.show(volumeDb: updated.volumeDb)
        }

        // Skip slider update during active hotkey use to avoid tug-of-war
        // between local prediction (accurate) and lagging server state
        if hotkeyManager?.isActivelyAdjusting == true {
            return
        }
        volumeController.updateSliderFromWebSocket(updated.volumeDb)
    }

    /// Limites poussées en direct par le backend (settings/volume_limits_changed)
    /// quand elles changent côté device. On ré-amorce le cache de l'API (lu par
    /// getVolumeStatus) ET la limite en mémoire pour que le slider du menu et le HUD
    /// du raccourci utilisent immédiatement les nouvelles bornes — sans re-fetch /bulk.
    /// Le raccourci relit currentVolume.limit* au début de chaque séquence.
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double) {
        connectionManager.apiService?.updateCachedLimits(minDb: minDb, maxDb: maxDb)

        if let existing = currentVolume {
            let updated = existing.withLimits(minDb: minDb, maxDb: maxDb)
            currentVolume = updated
            volumeController.setCurrentVolume(updated)
        }
        volumeController.updateVolumeLimits(minDb: minDb, maxDb: maxDb)

        scheduleMenuRefresh()
    }

    /// Apps du dock poussées en direct (settings/dock_apps_changed). Met à jour le
    /// filtre/ordre des sources ; rebuild si le menu est ouvert.
    func didReceiveDockAppsUpdate(_ enabledApps: [String]) {
        enabledDockApps = enabledApps
        scheduleMenuRefresh()
    }

    private func clearState() {
        currentState = nil
        currentVolume = nil
        enabledDockApps = nil
        volumeController.apiService = nil

        // Le cache radio doit être re-fetché à la reconnexion (les favoris ont
        // pu changer pendant la coupure), et un spinner de station en vol ne
        // doit pas survivre à la déconnexion.
        cachedRadioFavorites = nil
        radioSubmenu = nil
        endRadioStationLoading()

        loadingStates.keys.forEach { stopLoading(for: $0) }
        manualLoadingProtection.removeAll()
        expectedFunctionalityStates.removeAll()
    }
}
