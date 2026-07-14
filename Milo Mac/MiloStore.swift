import Foundation
import Observation

/// Source de vérité de l'UI. Remplace l'ancien MenuBarController : là où celui-ci
/// reconstruisait un NSMenu à chaque événement, les vues SwiftUI observent
/// directement ces propriétés et se re-rendent seules.
///
/// La machine à états de chargement (spinners) est portée à l'identique depuis
/// MenuBarController — c'est la partie subtile de cette classe, voir les commentaires
/// en regard de `syncLoadingStatesWithBackend`.
///
/// Comme MenuBarController avant elle, cette classe s'utilise **exclusivement depuis le
/// main thread** : MiloConnectionManager et WebSocketService dispatchent déjà tous leurs
/// appels delegate sur la main queue, et les Timers/asyncAfter d'ici y tournent aussi.
@Observable
final class MiloStore {

    // MARK: - État observé par les vues

    private(set) var isConnected = false
    private(set) var state: MiloState?
    private(set) var volume: VolumeStatus?
    private(set) var enabledApps: [String]?
    private(set) var radioFavorites: [RadioStation]?

    /// Spinners en cours, indexés par identifiant de source ("spotify"…) ou de
    /// fonctionnalité ("multiroom", "equalizer").
    private(set) var loadingStates: [String: Bool] = [:]

    /// Station radio dont la lecture est en vol : sa ligne affiche un spinner.
    private(set) var radioStationLoadingId: String?

    /// Valeur affichée par le slider. Écrite par l'utilisateur (drag) et par
    /// l'écho serveur — mais jamais par le serveur pendant que l'utilisateur
    /// manipule le slider (cf. `volumeController.isUserInteracting`).
    var sliderVolumeDb: Double = VolumeDefaults.limitMinDb

    /// Vrai tant que le panneau est ouvert. Sert uniquement à ne pas afficher le
    /// HUD de volume par-dessus le panneau, et à mettre en pause le poll de fond.
    var isPanelOpen = false

    /// Vrai quand le panneau a été ouvert avec la touche Option enfoncée : le pied
    /// (Paramètres, Quitter) n'apparaît qu'alors. Posé par MenuBarShell à l'ouverture.
    var showsPreferences = false

    // MARK: - Dépendances

    let connectionManager = MiloConnectionManager()
    let volumeController = VolumeController()
    private(set) var hotkeyManager: GlobalHotkeyManager?

    // MARK: - roc-vad

    /// Le driver audio virtuel n'est requis que par la source « Mac ». L'app fonctionne
    /// sans lui : il est exposé comme un **état** (la source apparaît désactivée, les
    /// Réglages proposent de l'installer), jamais comme une condition de démarrage.
    @ObservationIgnored private(set) var rocVADManager: RocVADManager?

    /// Vrai quand le binaire est installé **et** que le driver répond.
    private(set) var isRocVADReady = false

    /// Vrai entre la fin d'une installation et le redémarrage qui l'activera.
    private(set) var rocVADNeedsRestart = false

    private(set) var isInstallingRocVAD = false

    func attachRocVAD(_ manager: RocVADManager) {
        rocVADManager = manager
        connectionManager.rocVADManager = manager
    }

    /// Vérifie le driver et configure le device, en arrière-plan. Ne montre aucune alerte
    /// et ne bloque rien : si roc-vad manque, on se contente de le refléter dans l'UI.
    func prepareRocVADIfInstalled() {
        guard let rocVADManager, RocVADManager.isBinaryInstalled else {
            isRocVADReady = false
            return
        }

        // `roc-vad info` interroge le driver via gRPC et peut prendre plusieurs secondes.
        rocVADManager.checkInstallation { [weak self] driverLoaded in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isRocVADReady = driverLoaded

                guard driverLoaded else {
                    NSLog("⚠️ roc-vad installed but driver not loaded — restart pending")
                    self.rocVADNeedsRestart = true
                    return
                }

                // configureDeviceOnly doit tourner sur la deviceQueue sérielle du
                // manager : deux appels roc-vad concurrents se marchent dessus.
                rocVADManager.configureDeviceOnly { success in
                    NSLog(success ? "✅ roc-vad device configured" : "⚠️ roc-vad device configuration failed")
                }
            }
        }
    }

    /// Installe roc-vad à la demande, depuis les Réglages.
    func installRocVAD(completion: @escaping (Bool) -> Void) {
        guard let rocVADManager, !isInstallingRocVAD else { return }
        isInstallingRocVAD = true

        rocVADManager.performInstallation { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isInstallingRocVAD = false
                // Le driver n'est chargé qu'après redémarrage : on ne prétend pas être
                // prêt, on annonce ce qui reste à faire.
                self.rocVADNeedsRestart = success
                completion(success)
            }
        }
    }

    // MARK: - Limites de volume

    var volumeLimits: (minDb: Double, maxDb: Double) {
        guard let volume else {
            return (VolumeDefaults.limitMinDb, VolumeDefaults.limitMaxDb)
        }
        return (volume.limitMinDb, volume.limitMaxDb)
    }

    // MARK: - Loading (non observé : plomberie interne)

    @ObservationIgnored private var loadingTimers: [String: Timer] = [:]
    @ObservationIgnored private var loadingStartTimes: [String: Date] = [:]
    @ObservationIgnored private var manualLoadingProtection: [String: Date] = [:]
    @ObservationIgnored private var expectedFunctionalityStates: [String: Bool] = [:]
    @ObservationIgnored private var radioStationLoadingTimer: Timer?

    // MARK: - Poll de fond (non observé)

    @ObservationIgnored private var backgroundRefreshTimer: Timer?
    @ObservationIgnored private var consecutiveRefreshFailures = 0
    @ObservationIgnored private var refreshPausedUntil: Date?

    // MARK: - Constantes

    private let loadingTimeoutDuration: TimeInterval = 15.0
    private let functionalityLoadingTimeout: TimeInterval = 10.0
    // Multiroom prend plus longtemps côté backend (démarrage snapserver,
    // wait_for_ready jusqu'à 15 s, push du volume) — timeout de sécurité plus haut.
    private let multiroomLoadingTimeout: TimeInterval = 35.0
    private let minimumFunctionalityLoadingDuration: TimeInterval = 1.2
    // Fenêtre de grâce après un clic source : le temps que le backend prenne en
    // charge la transition (transition_start). Tant qu'elle court et que le backend
    // n'a pas encore confirmé, un état "non transitoire" est interprété comme
    // l'ancien état (race clic↔transition_start) et le spinner est gardé. Une fois
    // la transition prise en charge, on n'attend plus ce délai : le spinner s'efface
    // dès la fin de transition (comme le frontend web).
    private let manualLoadingGraceDuration: TimeInterval = 2.0
    private let radioStationLoadingTimeout: TimeInterval = 15.0
    private let maxConsecutiveFailures = 3
    // Le WebSocket pousse tous les changements d'état en temps réel : ce poll n'est
    // qu'un filet de sécurité lent pour rattraper un événement manqué.
    private let backgroundRefreshInterval: TimeInterval = 30.0
    private let refreshPauseDuration: TimeInterval = 60.0

    // MARK: - Cycle de vie

    init() {
        connectionManager.delegate = self
        hotkeyManager = GlobalHotkeyManager(connectionManager: connectionManager, store: self)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleVolumeChangedViaHotkey),
            name: .volumeChangedViaHotkey,
            object: nil
        )
    }

    func start() {
        connectionManager.start()
    }

    // MARK: - Actions

    func selectSource(_ sourceId: String) {
        guard let apiService = connectionManager.apiService, isConnected else { return }

        let activeSource = state?.activeSource ?? "none"
        guard activeSource != sourceId else { return }

        // Éviter les actions concurrentes pendant qu'une requête est en vol.
        guard loadingStates[sourceId] != true else { return }

        // Démarrer le loading AVANT la requête : spinner immédiat et anti
        // double-clic pendant les ~3 s que peut durer le POST.
        startLoading(for: sourceId, timeout: loadingTimeoutDuration)

        Task {
            do {
                try await apiService.changeSource(sourceId)
            } catch {
                // Échec HTTP ou {"status": "error"} in-band : pas de transition
                // à attendre, on arrête le spinner tout de suite.
                NSLog("❌ Source change to %@ failed: %@", sourceId, error.localizedDescription)
                await MainActor.run { self.stopLoading(for: sourceId) }
            }
        }
    }

    func toggleFeature(_ toggleId: String) {
        guard let apiService = connectionManager.apiService, isConnected else { return }
        guard loadingStates[toggleId] != true else { return }

        let newState = !currentToggleState(toggleId)
        startFunctionalityLoading(for: toggleId, expectedState: newState)

        Task {
            do {
                switch toggleId {
                case "multiroom":
                    try await apiService.setMultiroom(newState)
                case "equalizer":
                    try await apiService.setEqualizer(newState)
                default:
                    await MainActor.run { self.stopFunctionalityLoading(for: toggleId) }
                    return
                }
            } catch {
                // Multiroom : le PUT peut échouer même avec le timeout étendu pendant
                // que le backend termine la transition. On garde le spinner — il sera
                // résolu par multiroom_changed / multiroom_error via WebSocket, ou par
                // le timeout de sécurité. Pour les autres toggles, on arrête tout de suite.
                if toggleId != "multiroom" {
                    await MainActor.run { self.stopFunctionalityLoading(for: toggleId) }
                } else {
                    NSLog("⚠️ setMultiroom HTTP error (spinner kept until WS signal): %@", error.localizedDescription)
                }
            }
        }
    }

    func currentToggleState(_ toggleId: String) -> Bool {
        switch toggleId {
        case "multiroom": return state?.multiroomEnabled ?? false
        case "equalizer": return state?.equalizerEnabled ?? true
        default: return false
        }
    }

    /// État à afficher pour un toggle : pendant une transition on montre l'état
    /// **attendu**, pas celui du backend, sinon l'interrupteur reviendrait en
    /// arrière le temps de la requête.
    func displayedToggleState(_ toggleId: String) -> Bool {
        expectedFunctionalityStates[toggleId] ?? currentToggleState(toggleId)
    }

    // MARK: - Volume

    /// Appelé par le slider pendant que l'utilisateur le manipule.
    func setVolume(_ db: Double) {
        sliderVolumeDb = db
        volumeController.handleVolumeChange(db)
    }

    func updateVolumeStatus(_ volumeStatus: VolumeStatus) {
        volume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)
        applyServerVolume(volumeStatus.volumeDb)
    }

    /// Applique la valeur serveur au slider — sauf si l'utilisateur est en train de
    /// le manipuler, auquel cas l'écho (en retard) se disputerait le contrôle avec
    /// la valeur locale.
    private func applyServerVolume(_ db: Double) {
        guard !volumeController.isUserInteracting else { return }
        guard abs(sliderVolumeDb - db) > 0.1 else { return }
        sliderVolumeDb = db
    }

    @objc private func handleVolumeChangedViaHotkey(_ notification: Notification) {
        guard let volumeStatus = notification.object as? VolumeStatus else { return }

        volume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)
        applyServerVolume(volumeStatus.volumeDb)
    }

    // MARK: - Radio

    func playRadioStation(_ stationId: String) {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 playRadioStation: %@", stationId)

        beginRadioStationLoading(stationId: stationId)
        // Lire l'état sur le main thread (il y est possédé) plutôt que dans la
        // Task : la valeur pertinente est celle qu'a vue l'utilisateur au clic.
        let needsSourceSwitch = state?.activeSource != "radio"

        Task {
            do {
                try await apiService.playRadioStation(stationId)
                if needsSourceSwitch {
                    try await apiService.changeSource("radio")
                }
            } catch {
                NSLog("❌ Error playing radio: %@", error.localizedDescription)
                await MainActor.run { self.endRadioStationLoading() }
            }
        }
    }

    func stopRadioPlayback(_ stationId: String) {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 stopRadioPlayback: %@", stationId)

        Task {
            do {
                try await apiService.stopRadioPlayback()
            } catch {
                NSLog("❌ Error stopping radio: %@", error.localizedDescription)
            }
        }
    }

    /// Identifiant de la station en cours de lecture, ou nil.
    var playingRadioStationId: String? {
        let metadataIsPlaying = state?.metadata["is_playing"] as? Int == 1
        guard state?.activeSource == "radio", metadataIsPlaying else { return nil }
        return state?.metadata["station_id"] as? String
    }

    /// Vrai quand la source Radio est posée et que ses favoris peuvent s'afficher.
    var canShowRadioStations: Bool {
        state?.activeSource == "radio"
            && ["waiting", "active"].contains(state?.sourceState.lowercased() ?? "")
            && radioFavorites != nil
    }

    private func beginRadioStationLoading(stationId: String) {
        radioStationLoadingId = stationId
        radioStationLoadingTimer?.invalidate()

        let timer = Timer(timeInterval: radioStationLoadingTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in
                NSLog("⏱️ Radio station loading timeout — clearing spinner")
                self?.endRadioStationLoading()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        radioStationLoadingTimer = timer
    }

    private func endRadioStationLoading() {
        guard radioStationLoadingId != nil else { return }
        radioStationLoadingId = nil
        radioStationLoadingTimer?.invalidate()
        radioStationLoadingTimer = nil
    }

    private func loadRadioFavoritesInBackground() {
        guard let apiService = connectionManager.apiService else { return }

        Task {
            do {
                let favorites = try await apiService.getRadioFavorites()
                await MainActor.run {
                    self.radioFavorites = favorites
                    NSLog("✅ Radio favorites loaded: %d stations", favorites.count)
                }
            } catch {
                NSLog("❌ Failed to load radio favorites: %@", error.localizedDescription)
                await MainActor.run { self.radioFavorites = nil }
            }
        }
    }

    // MARK: - Loading : fonctionnalités (multiroom, equalizer)

    private func startFunctionalityLoading(for identifier: String, expectedState: Bool) {
        guard loadingStates[identifier] != true else { return }

        expectedFunctionalityStates[identifier] = expectedState
        loadingStartTimes[identifier] = Date()
        manualLoadingProtection[identifier] = Date()
        setLoadingState(for: identifier, isLoading: true)

        let safetyTimeout = identifier == "multiroom" ? multiroomLoadingTimeout : functionalityLoadingTimeout
        loadingTimers[identifier]?.invalidate()
        // Mode .common : le timeout de sécurité est la résolution de dernier recours
        // du spinner — il doit tomber même pendant un tracking d'événements.
        let timer = Timer(timeInterval: safetyTimeout, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.stopFunctionalityLoading(for: identifier) }
        }
        RunLoop.main.add(timer, forMode: .common)
        loadingTimers[identifier] = timer
    }

    private func stopFunctionalityLoading(for identifier: String) {
        // Durée minimale d'affichage : un toggle qui répond en 80 ms ne doit pas
        // faire clignoter le spinner.
        if let startTime = loadingStartTimes[identifier] {
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed < minimumFunctionalityLoadingDuration {
                let remaining = minimumFunctionalityLoadingDuration - elapsed
                DispatchQueue.main.asyncAfter(deadline: .now() + remaining) { [weak self] in
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
    }

    private func checkFunctionalityStateChange(_ newState: MiloState) {
        // Le loading multiroom est résolu par didReceiveMultiroomTransitionComplete,
        // pas en comparant l'état ici : le backend pré-positionne silencieusement
        // multiroom_enabled AVANT le vrai travail de routage (démarrage snapserver,
        // WebSocket prêt jusqu'à 15 s), donc les états intermédiaires portent déjà la
        // nouvelle valeur et résoudraient le spinner trop tôt.

        if let expectedEqualizer = expectedFunctionalityStates["equalizer"],
           newState.equalizerEnabled == expectedEqualizer,
           loadingStates["equalizer"] == true {
            stopFunctionalityLoading(for: "equalizer")
        }
    }

    // MARK: - Loading : sources audio

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
    }

    private func setLoadingState(for identifier: String, isLoading: Bool) {
        guard loadingStates[identifier] != isLoading else { return }
        loadingStates[identifier] = isLoading
    }

    /// Réconcilie les spinners de sources avec ce que dit le backend.
    ///
    /// C'est le point délicat de cette classe. Un clic pose un spinner *avant* la
    /// requête HTTP ; le backend peut mettre un instant à annoncer la transition
    /// (`transition_start`). Pendant cette fenêtre de grâce, un état "non transitoire"
    /// reçu est probablement l'**ancien** état (race clic↔transition_start) et ne doit
    /// pas effacer le spinner. Une fois la transition confirmée, la grâce est levée et
    /// le spinner s'efface dès la fin de transition — comme le frontend web.
    private func syncLoadingStatesWithBackend() {
        guard let state else { return }

        let audioSources = enabledApps?.filter { AudioSourceCatalog.allIds.contains($0) }
            ?? AudioSourceCatalog.allIds
        let isSourceTransitioning = state.sourceState.lowercased() == "starting" || state.transitioning

        for identifier in audioSources {
            if isSourceTransitioning && identifier == state.activeSource {
                // Le backend a pris en charge la transition de cette source.
                if loadingStates[identifier] != true {
                    setLoadingState(for: identifier, isLoading: true)
                }
                // Transition confirmée : on lève la fenêtre de grâce anti-race pour
                // pouvoir effacer le spinner DÈS la fin de transition, sans attendre
                // un délai fixe.
                manualLoadingProtection[identifier] = nil
            } else if loadingStates[identifier] == true {
                if let graceStart = manualLoadingProtection[identifier] {
                    let elapsed = Date().timeIntervalSince(graceStart)
                    if elapsed < manualLoadingGraceDuration {
                        // Re-vérifier à la fin de la fenêtre : sinon, si le backend
                        // n'émet plus rien (source posée en WAITING), le spinner
                        // resterait collé jusqu'au timeout de sécurité (15 s).
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

    /// Réévalue le spinner d'une source à la fin de sa fenêtre de grâce quand le backend
    /// n'a pas encore confirmé la transition, en re-vérifiant l'état courant (pour ne pas
    /// effacer une transition finalement prise en charge).
    private func scheduleGraceWindowSourceLoadingClear(_ identifier: String, after delay: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.loadingStates[identifier] == true, let state = self.state else { return }
            let stillTransitioning = (state.sourceState.lowercased() == "starting" || state.transitioning)
                && identifier == state.activeSource
            if !stillTransitioning {
                self.stopLoading(for: identifier)
            }
        }
    }

    // MARK: - Poll de fond

    private func startBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        consecutiveRefreshFailures = 0
        refreshPausedUntil = nil

        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: backgroundRefreshInterval, repeats: true) { [weak self] _ in
            guard let self, self.isConnected, !self.isPanelOpen else { return }

            // Pause auto-récupérante : après trop d'échecs consécutifs on attend
            // refreshPauseDuration puis on retente, au lieu de s'arrêter jusqu'à la
            // prochaine reconnexion.
            if let pausedUntil = self.refreshPausedUntil {
                guard Date() >= pausedUntil else { return }
                self.refreshPausedUntil = nil
                self.consecutiveRefreshFailures = 0
            }

            // Capturer le service sur le main thread : la propriété est possédée par
            // lui et nillée à la déconnexion.
            guard let apiService = self.connectionManager.apiService else { return }

            // Idem pour l'état : lu ici, sur le main thread qui le possède.
            // `enabledApps` encore nil = l'amorçage /bulk a échoué à la connexion. Sans
            // ce rattrapage il ne serait retenté qu'à la reconnexion suivante, et toute
            // la session tournerait sans filtre de sources ni vraies limites de volume.
            let needsBulkSettings = self.enabledApps == nil

            Task {
                // Le volume est poussé par WebSocket en temps réel, pas besoin de le
                // poll ici. Les réglages statiques (dock apps + limites) sont chargés
                // une fois à la connexion puis poussés par WebSocket — on ne les
                // retente donc que tant que cet amorçage n'a pas abouti.
                if needsBulkSettings {
                    await self.refreshBulkSettings(using: apiService)
                }

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

    // MARK: - Rafraîchissement

    /// Rafraîchit état + volume. Appelé à l'ouverture du panneau et à la connexion.
    func refreshPanelData() {
        guard let apiService = connectionManager.apiService else { return }

        if consecutiveRefreshFailures >= maxConsecutiveFailures {
            NSLog("🔄 Forcing API session reset due to persistent failures")
            apiService.resetSession()
            consecutiveRefreshFailures = 0
        }

        // Amorçage /bulk resté en échec : le rattraper AVANT le refresh volume, car
        // getVolumeStatus() lit les limites dans le cache que ce fetch amorce.
        let needsBulkSettings = enabledApps == nil

        Task {
            if needsBulkSettings {
                await self.refreshBulkSettings(using: apiService)
            }

            var attempts = 0
            let maxAttempts = 2

            while attempts < maxAttempts {
                async let stateResult = refreshState(using: apiService)
                async let volumeResult = refreshVolumeStatus(using: apiService)

                let stateSuccess = await stateResult
                let volumeSuccess = await volumeResult

                if stateSuccess || volumeSuccess {
                    await MainActor.run { self.consecutiveRefreshFailures = 0 }
                    return
                }

                attempts += 1
                if attempts < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            await MainActor.run {
                self.consecutiveRefreshFailures += 1
                NSLog("⚠️ Panel refresh failed after %d attempts", maxAttempts)
            }
        }
    }

    @discardableResult
    private func refreshState(using apiService: MiloAPIService) async -> Bool {
        do {
            let newState = try await apiService.fetchState()
            await MainActor.run {
                self.state = newState
                if newState.activeSource == "radio" && self.radioFavorites == nil {
                    self.loadRadioFavoritesInBackground()
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Réglages statiques (dock apps + limites volume) via /api/settings/bulk. Amorce
    /// aussi, par effet de bord côté MiloAPIService, le cache de limites lu par
    /// getVolumeStatus().
    @discardableResult
    private func refreshBulkSettings(using apiService: MiloAPIService) async -> Bool {
        do {
            let settings = try await apiService.fetchBulkSettings()
            await MainActor.run {
                self.enabledApps = settings.enabledApps

                // Amorçage tardif (rattrapage après un /bulk raté) : `volume` a pu être
                // lu entre-temps avec les limites de repli. Les recaler, sinon le slider
                // et le HUD resteraient mal bornés jusqu'au prochain volume_limits_changed.
                // Au premier amorçage `volume` est nil : ce bloc ne fait rien.
                if let existing = self.volume,
                   existing.limitMinDb != settings.limitMinDb || existing.limitMaxDb != settings.limitMaxDb {
                    let updated = existing.withLimits(minDb: settings.limitMinDb, maxDb: settings.limitMaxDb)
                    self.volume = updated
                    self.volumeController.setCurrentVolume(updated)
                }
            }
            return true
        } catch {
            return false
        }
    }

    /// Amorce les réglages statiques avec quelques essais espacés, comme le fait
    /// refreshPanelData pour l'état. Un unique /bulk raté à la connexion laisserait
    /// `enabledApps` nil — les sources s'afficheraient sans filtre ni ordre backend —
    /// et le volume borné aux valeurs de repli, jusqu'à la reconnexion suivante.
    private func bootstrapBulkSettings(using apiService: MiloAPIService) async {
        let maxAttempts = 3

        for attempt in 1...maxAttempts {
            if await refreshBulkSettings(using: apiService) { return }
            if attempt < maxAttempts {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }

        // Dernier filet : le poll de fond retentera tant que `enabledApps` est nil.
        NSLog("⚠️ Bulk settings bootstrap failed after %d attempts — background refresh will retry", maxAttempts)
    }

    @discardableResult
    private func refreshVolumeStatus(using apiService: MiloAPIService) async -> Bool {
        do {
            let volumeStatus = try await apiService.getVolumeStatus()
            await MainActor.run { self.updateVolumeStatus(volumeStatus) }
            return true
        } catch {
            return false
        }
    }

    private func clearState() {
        state = nil
        volume = nil
        enabledApps = nil
        volumeController.apiService = nil

        // Le cache radio doit être re-fetché à la reconnexion (les favoris ont pu
        // changer pendant la coupure), et un spinner de station en vol ne doit pas
        // survivre à la déconnexion.
        radioFavorites = nil
        endRadioStationLoading()

        loadingStates.keys.forEach { stopLoading(for: $0) }
        manualLoadingProtection.removeAll()
        expectedFunctionalityStates.removeAll()
    }
}

// MARK: - MiloConnectionManagerDelegate

extension MiloStore: MiloConnectionManagerDelegate {

    func miloDidConnect() {
        isConnected = true

        let apiService = connectionManager.apiService
        volumeController.apiService = apiService

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
            await self.bootstrapBulkSettings(using: apiService)
            await MainActor.run { self.refreshPanelData() }
        }
    }

    func miloDidDisconnect() {
        hotkeyManager?.stopMonitoring()
        stopBackgroundRefresh()

        isConnected = false

        clearState()
        volumeController.cleanup()
    }

    func didReceiveStateUpdate(_ newState: MiloState) {
        let previousSource = state?.activeSource
        state = newState

        // Charger les favoris si Radio est actif et que le cache est vide (que Radio
        // ait été activé depuis Milo Mac ou depuis le backend).
        if newState.activeSource == "radio" && radioFavorites == nil {
            loadRadioFavoritesInBackground()
        }

        // Effacer le cache si on quitte Radio.
        if newState.activeSource != "radio" && previousSource == "radio" {
            radioFavorites = nil
            NSLog("🗑️ Radio favorites cache cleared")
        }

        // Effacer le spinner de station dès la fin du buffering — couvre à la fois le
        // démarrage réussi et l'échec de chargement du flux, pour qu'il ne reste jamais
        // collé. Idem si Radio cesse d'être la source active.
        if radioStationLoadingId != nil {
            if newState.activeSource != "radio" {
                endRadioStationLoading()
            } else if newState.metadata["is_buffering"] as? Int != 1 {
                endRadioStationLoading()
            }
        }

        checkFunctionalityStateChange(newState)
        syncLoadingStatesWithBackend()
    }

    func didReceiveMultiroomTransitionComplete(success: Bool) {
        guard loadingStates["multiroom"] == true else { return }
        if !success {
            // Effacer l'état attendu en cas d'échec pour qu'aucun state_changed tardif
            // ne le résolve accidentellement.
            expectedFunctionalityStates["multiroom"] = nil
        }
        stopFunctionalityLoading(for: "multiroom")
    }

    func didReceiveVolumeUpdate(_ newVolume: VolumeStatus) {
        // Les événements volume du WebSocket ne portent PAS les limites (le service
        // envoie 0/0). Toujours substituer les limites en cache — stocker 0/0
        // briquerait le slider (intervalle vide), notamment dans la fenêtre entre la
        // connexion et le premier fetch volume où `volume` est encore nil.
        let fallback = (minDb: VolumeDefaults.limitMinDb, maxDb: VolumeDefaults.limitMaxDb)
        let cached = connectionManager.apiService?.cachedLimits ?? fallback
        let limits = volume.map { (minDb: $0.limitMinDb, maxDb: $0.limitMaxDb) } ?? cached
        let updated = newVolume.withLimits(minDb: limits.minDb, maxDb: limits.maxDb)

        volume = updated
        volumeController.setCurrentVolume(updated)

        // Afficher le HUD sur tout changement de volume si le réglage est actif —
        // sauf pendant l'usage du raccourci (il gère son propre HUD) et sauf quand le
        // panneau est ouvert (l'utilisateur voit déjà le slider).
        if UserDefaults.standard.bool(forKey: DefaultsKey.showVolumeHUDOnAllChanges),
           hotkeyManager?.isActivelyAdjusting != true,
           !isPanelOpen {
            hotkeyManager?.volumeHUD?.updateLimits(minDb: updated.limitMinDb, maxDb: updated.limitMaxDb)
            hotkeyManager?.volumeHUD?.show(volumeDb: updated.volumeDb)
        }

        // Ne pas bouger le slider pendant l'usage du raccourci : la prédiction locale
        // (exacte) se disputerait le contrôle avec l'état serveur (en retard).
        guard hotkeyManager?.isActivelyAdjusting != true else { return }
        applyServerVolume(updated.volumeDb)
    }

    /// Limites poussées en direct par le backend (settings/volume_limits_changed) quand
    /// elles changent côté device. On ré-amorce le cache de l'API (lu par
    /// getVolumeStatus) ET la limite en mémoire pour que le slider du panneau et le HUD
    /// du raccourci utilisent immédiatement les nouvelles bornes — sans re-fetch /bulk.
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double) {
        connectionManager.apiService?.updateCachedLimits(minDb: minDb, maxDb: maxDb)

        if let existing = volume {
            let updated = existing.withLimits(minDb: minDb, maxDb: maxDb)
            volume = updated
            volumeController.setCurrentVolume(updated)
        }
    }

    /// Apps du dock poussées en direct (settings/dock_apps_changed) : filtre et ordre
    /// des sources.
    func didReceiveDockAppsUpdate(_ apps: [String]) {
        enabledApps = apps
    }
}
