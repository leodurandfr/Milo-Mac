import Foundation
import Synchronization

/// Comme MiloConnectionManagerDelegate : les rappels sont resynchronisés sur le main
/// thread avant d'être émis (voir `parseMessage`).
@MainActor
protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect()
    /// La tentative de connexion a échoué avant que le handshake n'aboutisse
    /// (didOpen jamais reçu). Distinct de webSocketDidDisconnect pour que le
    /// connection manager puisse relancer la découverte depuis la phase
    /// .connecting au lieu d'y rester bloqué.
    func webSocketDidFailToConnect()
    func didReceiveStateUpdate(_ state: MiloState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
    func didReceiveMultiroomTransitionComplete(success: Bool)
    /// La *structure* multiroom a changé (un client s'est connecté/déconnecté, une zone a
    /// été créée/modifiée/supprimée). Le store re-fetch `/api/multiroom/state` plutôt que de
    /// réappliquer le diff d'union du wire — plus robuste, et la liste n'est pas assez grande
    /// pour que le coût compte.
    func didReceiveMultiroomStructureChanged()
    /// Volume/mute LIVE par client et par zone (porté par `volume/volume_changed` en mode
    /// multiroom). Alimente les sliders de la sous-section.
    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume)
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double)
    func didReceiveDockAppsUpdate(_ enabledApps: [String])
}

/// Transport WebSocket : les mises à jour poussées par le backend.
///
/// L'état de connexion (`webSocketTask`, `isOpen`, `isConnecting`, le timer de ping)
/// appartient au **main actor** — d'où `@MainActor` sur la classe. Mais URLSession livre
/// ses rappels sur SA queue déléguée : la boucle de réception, les rappels de ping et les
/// méthodes de `URLSessionWebSocketDelegate` sont donc `nonisolated`, et se resynchronisent
/// explicitement sur le main thread. C'est délibéré, et c'est ce que faisait déjà le code.
///
/// La **génération** est la seule donnée qui franchisse cette frontière : elle est lue
/// depuis la queue déléguée pour écarter les rappels d'une connexion périmée (un ping ou
/// une erreur de l'ancienne socket, arrivant après une reconnexion sleep/wake, ne doit pas
/// détruire la nouvelle). D'où le `Mutex` — là où un `NSLock` demandait au compilateur de
/// nous croire, il vérifie.
@MainActor
final class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isOpen = false
    // true entre connect() et didOpen — permet de signaler un échec de handshake.
    private var isConnecting = false

    /// Voir l'en-tête de classe : franchit la frontière d'isolation, donc sous verrou.
    private nonisolated let generation = Mutex(0)

    private nonisolated var currentGeneration: Int {
        generation.withLock { $0 }
    }

    // Ping
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0

    override init() {
        super.init()
        setupURLSession()
    }

    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15.0
        config.timeoutIntervalForResource = 60.0
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    // MARK: - Public API

    func connect(to urlString: String, generation newGeneration: Int) {
        NSLog("🔌 WebSocket connecting to %@ (gen %d)", urlString, newGeneration)

        cleanupCurrentConnection()
        // Ne pas dépendre de l'ordre d'appel du caller (resetSession avant
        // connect) : l'état "ouvert" appartient au cycle de vie de la connexion.
        isOpen = false
        generation.withLock { $0 = newGeneration }

        guard let url = URL(string: urlString) else {
            NSLog("❌ Invalid WebSocket URL: %@", urlString)
            return
        }

        isConnecting = true
        let task = urlSession!.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        startListening(task: task, generation: newGeneration)
    }

    /// Closes the connection without notifying the delegate.
    /// Callers are responsible for managing their own state after a deliberate disconnect.
    func disconnect() {
        cleanupCurrentConnection()
        isOpen = false
        isConnecting = false
    }

    func resetSession() {
        cleanupCurrentConnection()
        isOpen = false
        isConnecting = false
        urlSession?.invalidateAndCancel()
        setupURLSession()
        NSLog("🔄 WebSocket URLSession reset")
    }

    // MARK: - Private

    private func cleanupCurrentConnection() {
        pingTimer?.invalidate()
        pingTimer = nil
        webSocketTask?.cancel()
        webSocketTask = nil
    }

    /// La boucle de réception capture sa propre task : le callback (queue
    /// déléguée URLSession) ne relit jamais self.webSocketTask, qui est écrit
    /// sur le main thread — pas de lecture croisée non synchronisée.
    ///
    /// `nonisolated` : elle tourne sur la queue déléguée d'URLSession, et se rappelle
    /// elle-même depuis ce même rappel.
    private nonisolated func startListening(task: URLSessionWebSocketTask, generation: Int) {
        task.receive { [weak self] result in
            guard let self = self, self.currentGeneration == generation else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                if self.currentGeneration == generation {
                    self.startListening(task: task, generation: generation)
                }

            case .failure(let error):
                NSLog("❌ WebSocket receive error (gen %d): %@", generation, error.localizedDescription)
                DispatchQueue.main.async { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self = self, self.currentGeneration == generation else {
                            NSLog("💔 Stale WebSocket error (gen %d), ignoring", generation)
                            return
                        }
                        self.handleSocketError()
                    }
                }
            }
        }
    }

    private func handleSocketError() {
        cleanupCurrentConnection()

        if isOpen {
            isOpen = false
            isConnecting = false
            delegate?.webSocketDidDisconnect()
        } else if isConnecting {
            // Handshake jamais abouti (port fermé, backend WS pas encore prêt) :
            // sans ce signal, le connection manager resterait en .connecting
            // pour toujours — aucune autre voie de récupération n'est active.
            isConnecting = false
            delegate?.webSocketDidFailToConnect()
        }
    }

    // MARK: - Message Handling

    private nonisolated func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseMessage(text)
            }
        @unknown default:
            break
        }
    }

    /// Un événement **décodé**, prêt à être livré au delegate.
    ///
    /// Sendable, et c'est tout l'intérêt : le décodage a lieu sur la queue déléguée
    /// d'URLSession, la livraison sur le main actor. Faire traverser le `[String: Any]`
    /// brut (non-Sendable) obligerait à mentir au compilateur ; on fait donc traverser le
    /// résultat typé, ce qui déplace au passage tout le parsing hors du main thread.
    private enum DecodedEvent: Sendable {
        /// Toute mise à jour d'état portant full_state (catégories "source" et "system",
        /// _FULL_STATE_CATEGORIES côté backend). L'état EQ arrive via le system/state_changed
        /// compagnon, pas via equalizer/enabled_changed.
        case state(MiloState, multiroomChanged: Bool)
        case volume(VolumeStatus, multiroom: MultiroomVolume?)
        case multiroomFailed
        case multiroomStructureChanged
        case volumeLimits(minDb: Double, maxDb: Double)
        case dockApps([String])
    }

    private nonisolated func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let category = json["category"] as? String,
              let eventType = json["type"] as? String,
              let eventData = json["data"] as? [String: Any] else {
            return
        }

        // Le backend diffuse en broadcast à TOUS les clients : milo-mac reçoit
        // donc aussi quantité d'events destinés au frontend web
        // (settings/fan_status_changed, settings/bt_remote_status_changed,
        // settings/mac_roc_changed, routing/multiroom_ready, equalizer/levels,
        // system/ping…) qu'il ne consomme pas. On ne logge et ne traite QUE les
        // events utiles — le reste est ignoré silencieusement, sans hop main-thread.
        let decoded: DecodedEvent?
        switch (category, eventType) {
        case ("system", "state_changed"),
             ("system", "transition_complete"),
             ("system", "transition_start"),
             ("source", "state_changed"):
            decoded = Self.decodeState(eventData)
        case ("volume", "volume_changed"):
            decoded = Self.decodeVolume(eventData)
        case ("routing", "multiroom_error"):
            decoded = .multiroomFailed
        case ("multiroom", "client_state_changed"),
             ("multiroom", "zone_changed"):
            // Un seul signal côté store : la structure a bougé, re-fetch. On ne distingue
            // pas client vs zone — le re-fetch couvre les deux.
            decoded = .multiroomStructureChanged
        case ("settings", "volume_limits_changed"):
            decoded = Self.decodeVolumeLimits(eventData)
        case ("settings", "dock_apps_changed"):
            decoded = Self.decodeDockApps(eventData)
        default:
            return
        }

        NSLog("📨 WebSocket event: %@/%@ (gen %d)", category, eventType, currentGeneration)

        guard let decoded else { return }

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.deliver(decoded) }
        }
    }

    private func deliver(_ event: DecodedEvent) {
        switch event {
        case .state(let state, let multiroomChanged):
            delegate?.didReceiveStateUpdate(state)

            // The backend silently pre-sets multiroom_enabled at the start of a
            // routing transition, then broadcasts many intermediate source state
            // changes that all carry the new multiroom_enabled in full_state.
            // Only the final update_multiroom_state broadcast carries the
            // multiroom_changed discriminator — treat it as the authoritative
            // completion signal for the multiroom loading spinner.
            if multiroomChanged {
                delegate?.didReceiveMultiroomTransitionComplete(success: true)
            }

        case .volume(let volume, let multiroom):
            delegate?.didReceiveVolumeUpdate(volume)
            // En mode multiroom, le même événement porte le volume/mute par client et par
            // zone (`state.clients` / `state.zones`) — la source LIVE des sliders de la
            // sous-section.
            if let multiroom {
                delegate?.didReceiveMultiroomVolumeUpdate(multiroom)
            }

        case .multiroomFailed:
            delegate?.didReceiveMultiroomTransitionComplete(success: false)

        case .multiroomStructureChanged:
            delegate?.didReceiveMultiroomStructureChanged()

        case .volumeLimits(let minDb, let maxDb):
            delegate?.didReceiveVolumeLimitsUpdate(minDb: minDb, maxDb: maxDb)

        case .dockApps(let apps):
            delegate?.didReceiveDockAppsUpdate(apps)
        }
    }

    // MARK: - Décodage (hors main thread)

    private nonisolated static func decodeState(_ data: [String: Any]) -> DecodedEvent? {
        guard let fullState = data["full_state"] as? [String: Any] else { return nil }
        return .state(MiloState(json: fullState),
                      multiroomChanged: data["multiroom_changed"] as? Bool == true)
    }

    private nonisolated static func decodeVolume(_ data: [String: Any]) -> DecodedEvent? {
        let volumeDb: Double
        let state = data["state"] as? [String: Any]

        // Priorité au nouveau format (state.global_volume_db)
        if let state = state, let db = state["global_volume_db"] as? Double {
            volumeDb = db
        } else if let state = state, let globalStr = state["global_volume_db"] as? String,
                  let db = Double(globalStr) {
            volumeDb = db
        } else if let db = data["volume_db"] as? Double {
            volumeDb = db
        } else if let db = data["volume_db"] as? Int {
            volumeDb = Double(db)
        } else {
            return nil
        }

        let mode = state?["mode"] as? String
        let multiroomEnabled = (mode == "multiroom") || (data["multiroom_enabled"] as? Bool ?? false)

        // Volume/mute par client et par zone : seulement en mode multiroom, et seulement s'il
        // y a effectivement des clients/zones (sinon nil, on ne réveille pas le store pour rien).
        let multiroom: MultiroomVolume?
        if let state, mode == "multiroom" {
            let mv = MultiroomVolume(state: state)
            multiroom = (mv.clients.isEmpty && mv.zones.isEmpty) ? nil : mv
        } else {
            multiroom = nil
        }

        // Les limites ne sont pas dans les événements WebSocket ; elles sont préservées
        // depuis le cache API par `MiloStore.didReceiveVolumeUpdate`.
        return .volume(VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: multiroomEnabled,
            dspAvailable: true,
            limitMinDb: 0,
            limitMaxDb: 0
        ), multiroom: multiroom)
    }

    // settings/volume_limits_changed → data.limits.{min_db,max_db}
    // (même enveloppe "limits" que l'ancienne route /api/settings/volume-limits)
    private nonisolated static func decodeVolumeLimits(_ data: [String: Any]) -> DecodedEvent? {
        guard let limits = data["limits"] as? [String: Any],
              let minDb = (limits["min_db"] as? Double) ?? (limits["min_db"] as? Int).map(Double.init),
              let maxDb = (limits["max_db"] as? Double) ?? (limits["max_db"] as? Int).map(Double.init),
              minDb < maxDb else { return nil }  // garde-fou : jamais de 0/0 ni de plage inversée

        return .volumeLimits(minDb: minDb, maxDb: maxDb)
    }

    // settings/dock_apps_changed → data.config.enabled_apps
    private nonisolated static func decodeDockApps(_ data: [String: Any]) -> DecodedEvent? {
        guard let config = data["config"] as? [String: Any],
              let enabledApps = config["enabled_apps"] as? [String] else { return nil }

        return .dockApps(enabledApps)
    }

    // MARK: - Ping

    private func startPingTimer() {
        pingTimer?.invalidate()
        // Mode .common : le keepalive doit survivre au suivi de la souris — glisser le slider
        // ou faire défiler la liste des stations bascule la run loop en `.eventTracking`, où
        // un timer posé dans le seul mode par défaut ne se déclencherait plus.
        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func sendPing() {
        guard isOpen else { return }

        // Capturer la génération : un ping de l'ancienne connexion dont le
        // callback d'erreur arrive après une reconnexion (sleep/wake) ne doit
        // pas détruire la nouvelle connexion, déjà ouverte.
        let pingGeneration = currentGeneration
        webSocketTask?.sendPing { [weak self] error in
            // Rappel livré sur la queue déléguée d'URLSession.
            if let error = error {
                NSLog("❌ Ping failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        guard let self = self, self.currentGeneration == pingGeneration else { return }
                        self.handleSocketError()
                    }
                }
            }
        }
    }

    isolated deinit {
        cleanupCurrentConnection()
    }
}

// MARK: - URLSessionWebSocketDelegate

/// Livrées sur la queue déléguée d'URLSession, d'où `nonisolated` : chacune se
/// resynchronise sur le main thread, où vit l'état de connexion.
extension WebSocketService: URLSessionWebSocketDelegate {
    nonisolated func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("✅ WebSocket connected (gen %d)", currentGeneration)

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.webSocketTask === task else {
                    NSLog("💔 Stale WebSocket didOpen callback, ignoring")
                    return
                }
                self.isOpen = true
                self.isConnecting = false
                self.startPingTimer()
                self.delegate?.webSocketDidConnect()
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
        NSLog("🔌 WebSocket closed (gen %d): %d - %@", currentGeneration, closeCode.rawValue, reasonString)

        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self = self, self.webSocketTask === task else {
                    NSLog("💔 Stale WebSocket didClose callback, ignoring")
                    return
                }
                self.handleSocketError()
            }
        }
    }
}
