import Foundation
import Observation

/// Source de vérité de l'UI : les vues SwiftUI observent ces propriétés et se re-rendent
/// seules. Rien ne reconstruit de menu à chaque événement.
///
/// La machine à états de chargement (les spinners) est la partie subtile de cette classe —
/// voir les commentaires en regard de `syncLoadingStatesWithBackend`.
///
/// Cette classe s'utilise **exclusivement depuis le main thread**, et `@MainActor` le fait
/// vérifier par le compilateur au lieu de le confier à ce commentaire : MiloConnectionManager
/// et WebSocketService livrent déjà tous leurs appels delegate sur le main actor, et les
/// Timers/asyncAfter d'ici y tournent aussi. Les `Task` créées ici en héritent — d'où
/// l'absence de `MainActor.run` : après un `await` réseau, on est déjà revenu sur le main.
@MainActor
@Observable
final class MiloStore {

    // MARK: - État observé par les vues

    private(set) var isConnected = false
    private(set) var state: MiloState?
    private(set) var volume: VolumeStatus?
    private(set) var enabledApps: [String]?
    private(set) var radioFavorites: [RadioStation]?

    /// Structure multiroom (zones + clients), lue quand le multiroom est activé. Vide sinon.
    /// Alimente la sous-section dépliable de la ligne Multiroom.
    private(set) var multiroom: MultiroomSnapshot = .empty

    /// Volume/mute EN DIRECT par client et par zone (moyennes de zone incluses). Amorcé avec
    /// la structure, puis poussé par `volume/volume_changed`. Alimente les sliders et boutons
    /// muet de la sous-section.
    private(set) var multiroomVolume: MultiroomVolume = .empty

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

    /// Vrai quand la sous-section multiroom est dépliée sous la ligne Multiroom.
    ///
    /// Dans le store, et non en `@State` local de la vue, pour deux raisons : `MenuBarShell`
    /// l'observe pour redimensionner la fenêtre (le panneau grandit/rétrécit avec l'accordéon,
    /// comme le panneau « Son » sous AirPods) ; et il doit se refermer à la fermeture du panneau
    /// ou quand le multiroom est coupé.
    var multiroomExpanded = false

    /// Fraction d'ouverture de l'accordéon multiroom, de 0 (replié) à 1 (déplié). Animée par un
    /// timer dans `MenuBarShell` (et NON par `withAnimation`) : la sous-section a une hauteur de
    /// `naturelle × fraction`, si bien qu'à chaque pas le contenu SwiftUI a une taille CONCRÈTE,
    /// sur laquelle `MenuBarShell` recale la fenêtre — là où `withAnimation` rapporterait la
    /// taille finale d'un coup à `NSHostingController`, faisant sauter la fenêtre.
    var multiroomRevealFraction: CGFloat = 0

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

        Task {
            // `roc-vad info` interroge le driver via gRPC et peut prendre plusieurs
            // secondes — d'où l'await, qui n'immobilise pas le main thread.
            let driverLoaded = await rocVADManager.checkInstallation()
            isRocVADReady = driverLoaded

            guard driverLoaded else {
                NSLog("⚠️ roc-vad installed but driver not loaded — restart pending")
                rocVADNeedsRestart = true
                return
            }

            let success = await rocVADManager.configureDeviceOnly()
            NSLog(success ? "✅ roc-vad device configured" : "⚠️ roc-vad device configuration failed")
        }
    }

    /// Installe roc-vad à la demande, depuis les Réglages.
    func installRocVAD(completion: @escaping @MainActor (Bool) -> Void) {
        guard let rocVADManager, !isInstallingRocVAD else { return }
        isInstallingRocVAD = true

        Task {
            let success = await rocVADManager.performInstallation()
            isInstallingRocVAD = false
            // Le driver n'est chargé qu'après redémarrage : on ne prétend pas être
            // prêt, on annonce ce qui reste à faire.
            rocVADNeedsRestart = success
            completion(success)
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
                stopLoading(for: sourceId)
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
                    stopFunctionalityLoading(for: toggleId)
                    return
                }
            } catch {
                // Multiroom : le PUT peut échouer même avec le timeout étendu pendant
                // que le backend termine la transition. On garde le spinner — il sera
                // résolu par multiroom_changed / multiroom_error via WebSocket, ou par
                // le timeout de sécurité. Pour les autres toggles, on arrête tout de suite.
                if toggleId != "multiroom" {
                    stopFunctionalityLoading(for: toggleId)
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

    /// Applique au slider une valeur venue du SERVEUR. Point de passage unique de tous les
    /// chemins serveur : écho WebSocket, poll de fond, et le `GET /api/volume/state` que le
    /// raccourci déclenche en début de séquence (`refreshVolumeLimitsInBackground`).
    ///
    /// Le slider a deux pilotes possibles, et il ne faut jamais laisser le second écraser le
    /// premier : une valeur LOCALE (immédiate, exacte) et l'écho SERVEUR de cette même valeur
    /// (qui arrive un aller-retour réseau plus tard). D'où les trois gardes ci-dessous — une
    /// par pilote local, plus la fenêtre d'écoulement qui suit.
    ///
    /// - `isUserInteracting` : l'utilisateur fait glisser le slider à la souris.
    /// - `isActivelyAdjusting` : le raccourci clavier tient sa prédiction locale. Sans cette
    ///   garde, le `GET` de début de séquence renvoie le volume d'AVANT le delta (son `adjust`
    ///   n'a pas encore atterri) et ramenait le thumb en arrière.
    /// - `isHotkeySettling` : voir ci-dessous.
    private func applyServerVolume(_ db: Double) {
        guard !volumeController.isUserInteracting else { return }
        guard hotkeyManager?.isActivelyAdjusting != true, !isHotkeySettling else { return }
        setSliderVolume(db)
    }

    /// Fenêtre pendant laquelle les échos serveur restent ignorés APRÈS le dernier cran du
    /// raccourci.
    ///
    /// `isActivelyAdjusting` retombe à faux dès le relâchement de la touche — au pire instant
    /// possible. Un maintien tique toutes les 30 ms, bien plus vite que l'aller-retour vers le
    /// Pi, et les `adjust` sont sérialisés : au relâchement, les échos des crans précédents
    /// sont donc encore en vol. La garde s'ouvrant pile à ce moment, ils atterrissaient tous,
    /// ramenaient le thumb sur une valeur périmée, et le dernier écho le rattrapait ensuite —
    /// le petit saut au relâchement.
    ///
    /// On rend donc la main au serveur non pas au relâchement, mais une fois ses échos écoulés.
    /// C'est exactement la parade (et la durée) que `VolumeController` applique déjà au
    /// glissement souris, où les échos accusent le même retard : `userInteractionTimeout`.
    /// Non observée : plomberie interne, et réécrite à chaque cran (30 Hz) — l'exposer au
    /// graphe d'observation ferait tourner les vues pour rien.
    @ObservationIgnored private var hotkeySettleUntil: Date?
    private let hotkeySettleDuration: TimeInterval = 0.3

    private var isHotkeySettling: Bool {
        guard let hotkeySettleUntil else { return false }
        return Date() < hotkeySettleUntil
    }

    /// Zone morte : sous 0,1 dB, réécrire ne ferait que déclencher un rendu pour rien.
    private func setSliderVolume(_ db: Double) {
        guard abs(sliderVolumeDb - db) > 0.1 else { return }
        sliderVolumeDb = db
    }

    @objc private func handleVolumeChangedViaHotkey(_ notification: Notification) {
        guard let volumeStatus = notification.object as? VolumeStatus else { return }

        volume = volumeStatus
        volumeController.setCurrentVolume(volumeStatus)

        // Chaque cran repousse la fenêtre : elle court donc 0,3 s après le DERNIER, qu'il y ait
        // eu maintien ou simple appui.
        hotkeySettleUntil = Date().addingTimeInterval(hotkeySettleDuration)

        // La prédiction LOCALE du raccourci, et non un écho serveur : elle court-circuite
        // `applyServerVolume`, dont c'est justement elle qui arme les gardes.
        setSliderVolume(volumeStatus.volumeDb)
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
                endRadioStationLoading()
            }
        }
    }

    /// Arrête la lecture, sans dire laquelle : `/api/radio/stop` ne prend pas de station —
    /// le backend n'en joue qu'une à la fois.
    func stopRadioPlayback() {
        guard let apiService = connectionManager.apiService else { return }
        NSLog("📻 stopRadioPlayback")

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
                radioFavorites = favorites
                NSLog("✅ Radio favorites loaded: %d stations", favorites.count)
            } catch {
                NSLog("❌ Failed to load radio favorites: %@", error.localizedDescription)
                radioFavorites = nil
            }
        }
    }

    // MARK: - Multiroom

    /// Vrai quand la sous-section multiroom peut s'afficher : le multiroom est actif ET le
    /// registre a au moins un élément à montrer. Le chevron de la ligne Multiroom n'apparaît
    /// qu'alors (comme le caret Radio, gardé par `canShowRadioStations`).
    var canShowMultiroom: Bool {
        state?.multiroomEnabled == true && !multiroomDisplayItems.isEmpty
    }

    /// La liste ordonnée pour l'affichage : les zones (chacune avec ses clients membres),
    /// puis les clients standalone. Trié en-ligne-d'abord, zones avant clients, puis
    /// alphabétique — le même langage que la section « Sortie » de « Son » et que le
    /// frontend web du multiroom.
    var multiroomDisplayItems: [MultiroomDisplayItem] {
        let clientsInZones = Set(multiroom.zones.values.flatMap { $0.clientIds })

        var items: [MultiroomDisplayItem] = []

        for zone in multiroom.zones.values {
            // On garde l'ordre des membres tel que le backend l'a trié (local d'abord).
            let members = zone.clientIds.compactMap { multiroom.clients[$0] }
            guard !members.isEmpty else { continue }
            items.append(.zone(zone, clients: members))
        }

        for client in multiroom.clients.values
        where client.zoneId == nil && !clientsInZones.contains(client.macId) {
            items.append(.standalone(client))
        }

        return items.sorted { lhs, rhs in
            if lhs.isOnline != rhs.isOnline { return lhs.isOnline }
            if lhs.isZone != rhs.isZone { return lhs.isZone }
            return lhs.sortName.localizedCaseInsensitiveCompare(rhs.sortName) == .orderedAscending
        }
    }

    /// Recharge la structure multiroom ET le volume live depuis le backend. Appelé à
    /// l'ouverture de la sous-section, quand le multiroom passe actif, et sur tout événement
    /// WebSocket de structure. Silencieux en cas d'échec : on garde la dernière valeur connue.
    func loadMultiroomState() {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do {
                async let structure = apiService.fetchMultiroomState()
                async let volume = apiService.fetchMultiroomVolume()
                multiroom = try await structure
                multiroomVolume = try await volume
            } catch {
                NSLog("❌ Failed to load multiroom state: %@", error.localizedDescription)
            }
        }
    }

    // MARK: - Actions multiroom (volume / mute)

    /// Fixe le volume ABSOLU d'un client. Fire-and-forget : le backend rediffuse le nouvel
    /// état par `volume/volume_changed`, qui met `multiroomVolume` à jour.
    func setClientVolume(mac: String, volumeDb: Double) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do { try await apiService.setClientVolume(mac: mac, volumeDb: volumeDb) }
            catch { NSLog("❌ setClientVolume failed: %@", error.localizedDescription) }
        }
    }

    /// Bascule le mute d'un client.
    func setClientMute(mac: String, muted: Bool) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do { try await apiService.setClientMute(mac: mac, muted: muted) }
            catch { NSLog("❌ setClientMute failed: %@", error.localizedDescription) }
        }
    }

    /// Applique un DELTA de volume à une zone (le backend le répercute sur ses clients).
    func setZoneVolumeDelta(zoneId: String, deltaDb: Double) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            do { try await apiService.setZoneVolumeDelta(zoneId: zoneId, deltaDb: deltaDb) }
            catch { NSLog("❌ setZoneVolumeDelta failed: %@", error.localizedDescription) }
        }
    }

    /// Mute/démute une zone entière — le backend n'a pas d'endpoint de zone pour le mute, on
    /// le pose donc client par client (comme le frontend web), sur les seuls MAC fournis.
    func setZoneMute(clientMacs: [String], muted: Bool) {
        guard let apiService = connectionManager.apiService else { return }
        Task {
            for mac in clientMacs {
                do { try await apiService.setClientMute(mac: mac, muted: muted) }
                catch { NSLog("❌ setZoneMute(%@) failed: %@", mac, error.localizedDescription) }
            }
        }
    }

    /// Synchronise le cache multiroom avec l'état courant : on le charge dès que le
    /// multiroom est actif (et pas encore chargé), on le vide quand il est coupé. Appelé sur
    /// chaque nouvel état (fetch HTTP comme push WebSocket).
    private func syncMultiroomState(for newState: MiloState) {
        if newState.multiroomEnabled {
            if multiroom.clients.isEmpty { loadMultiroomState() }
        } else if !multiroom.clients.isEmpty || !multiroom.zones.isEmpty {
            multiroom = .empty
            multiroomVolume = .empty
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
                    MainActor.assumeIsolated { self?.stopFunctionalityLoading(for: identifier) }
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
            MainActor.assumeIsolated {
                guard let self, self.loadingStates[identifier] == true, let state = self.state else { return }
                let stillTransitioning = (state.sourceState.lowercased() == "starting" || state.transitioning)
                    && identifier == state.activeSource
                if !stillTransitioning {
                    self.stopLoading(for: identifier)
                }
            }
        }
    }

    // MARK: - Poll de fond

    private func startBackgroundRefresh() {
        backgroundRefreshTimer?.invalidate()
        consecutiveRefreshFailures = 0
        refreshPausedUntil = nil

        backgroundRefreshTimer = Timer.scheduledTimer(withTimeInterval: backgroundRefreshInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runBackgroundRefreshTick() }
        }
    }

    private func runBackgroundRefreshTick() {
        guard isConnected, !isPanelOpen else { return }

        // Pause auto-récupérante : après trop d'échecs consécutifs on attend
        // refreshPauseDuration puis on retente, au lieu de s'arrêter jusqu'à la
        // prochaine reconnexion.
        if let pausedUntil = refreshPausedUntil {
            guard Date() >= pausedUntil else { return }
            refreshPausedUntil = nil
            consecutiveRefreshFailures = 0
        }

        // La propriété est possédée par le main thread et nillée à la déconnexion.
        guard let apiService = connectionManager.apiService else { return }

        // `enabledApps` encore nil = l'amorçage /bulk a échoué à la connexion. Sans
        // ce rattrapage il ne serait retenté qu'à la reconnexion suivante, et toute
        // la session tournerait sans filtre de sources ni vraies limites de volume.
        let needsBulkSettings = enabledApps == nil

        Task {
            // Le volume est poussé par WebSocket en temps réel, pas besoin de le
            // poll ici. Les réglages statiques (dock apps + limites) sont chargés
            // une fois à la connexion puis poussés par WebSocket — on ne les
            // retente donc que tant que cet amorçage n'a pas abouti.
            if needsBulkSettings {
                await refreshBulkSettings(using: apiService)
            }

            let stateSuccess = await refreshState(using: apiService)

            if stateSuccess {
                consecutiveRefreshFailures = 0
            } else {
                consecutiveRefreshFailures += 1
                if consecutiveRefreshFailures >= maxConsecutiveFailures {
                    NSLog("⚠️ Background refresh paused after %d failures", consecutiveRefreshFailures)
                    refreshPausedUntil = Date().addingTimeInterval(refreshPauseDuration)
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
                await refreshBulkSettings(using: apiService)
            }

            var attempts = 0
            let maxAttempts = 2

            while attempts < maxAttempts {
                async let stateResult = refreshState(using: apiService)
                async let volumeResult = refreshVolumeStatus(using: apiService)

                let stateSuccess = await stateResult
                let volumeSuccess = await volumeResult

                if stateSuccess || volumeSuccess {
                    consecutiveRefreshFailures = 0
                    return
                }

                attempts += 1
                if attempts < maxAttempts {
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }

            consecutiveRefreshFailures += 1
            NSLog("⚠️ Panel refresh failed after %d attempts", maxAttempts)
        }
    }

    @discardableResult
    private func refreshState(using apiService: MiloAPIService) async -> Bool {
        do {
            let newState = try await apiService.fetchState()
            state = newState
            if newState.activeSource == "radio" && radioFavorites == nil {
                loadRadioFavoritesInBackground()
            }
            syncMultiroomState(for: newState)
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
            enabledApps = settings.enabledApps

            // Amorçage tardif (rattrapage après un /bulk raté) : `volume` a pu être
            // lu entre-temps avec les limites de repli. Les recaler, sinon le slider
            // et le HUD resteraient mal bornés jusqu'au prochain volume_limits_changed.
            // Au premier amorçage `volume` est nil : ce bloc ne fait rien.
            if let existing = volume,
               existing.limitMinDb != settings.limitMinDb || existing.limitMaxDb != settings.limitMaxDb {
                let updated = existing.withLimits(minDb: settings.limitMinDb, maxDb: settings.limitMaxDb)
                volume = updated
                volumeController.setCurrentVolume(updated)
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
            updateVolumeStatus(volumeStatus)
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

        // La structure multiroom sera re-fetchée à la reconnexion si le multiroom est actif.
        multiroom = .empty
        multiroomVolume = .empty

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
            self.refreshPanelData()
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
        syncMultiroomState(for: newState)
    }

    func didReceiveMultiroomStructureChanged() {
        // Seulement quand le multiroom est actif : sinon la sous-section est masquée et un
        // re-fetch ne servirait à rien.
        guard state?.multiroomEnabled == true else { return }
        loadMultiroomState()
    }

    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume) {
        multiroomVolume = volume
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

        // `applyServerVolume` sait déjà se taire pendant le raccourci et pendant un glissement.
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

// MARK: - Élément d'affichage multiroom

/// Une entrée de la sous-section multiroom : soit une zone (avec la liste ordonnée de ses
/// clients membres, affichés indentés dessous), soit un client standalone.
///
/// Construit sur le main actor à partir du `MultiroomSnapshot` (voir
/// `MiloStore.multiroomDisplayItems`) ; pas besoin qu'il soit `Sendable`, il ne franchit
/// aucune frontière d'isolation.
enum MultiroomDisplayItem: Identifiable {
    case zone(MultiroomZone, clients: [MultiroomClient])
    case standalone(MultiroomClient)

    var id: String {
        switch self {
        case .zone(let zone, _): return "zone:\(zone.id)"
        case .standalone(let client): return "client:\(client.macId)"
        }
    }

    var isZone: Bool {
        if case .zone = self { return true }
        return false
    }

    /// En ligne si l'élément est joignable — pour une zone, dès qu'un de ses clients l'est.
    var isOnline: Bool {
        switch self {
        case .zone(_, let clients): return clients.contains { $0.online }
        case .standalone(let client): return client.online
        }
    }

    var sortName: String {
        switch self {
        case .zone(let zone, _): return zone.name
        case .standalone(let client): return client.name
        }
    }
}
