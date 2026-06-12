import Foundation

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
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double)
    func didReceiveDockAppsUpdate(_ enabledApps: [String])
}

class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isOpen = false
    // true entre connect() et didOpen — permet de signaler un échec de handshake.
    private var isConnecting = false

    // Generation tracking (thread-safe via NSLock for background receive callbacks)
    private let generationLock = NSLock()
    private var _currentGeneration: Int = 0
    private var currentGeneration: Int {
        get { generationLock.withLock { _currentGeneration } }
        set { generationLock.withLock { _currentGeneration = newValue } }
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

    func connect(to urlString: String, generation: Int) {
        NSLog("🔌 WebSocket connecting to %@ (gen %d)", urlString, generation)

        cleanupCurrentConnection()
        // Ne pas dépendre de l'ordre d'appel du caller (resetSession avant
        // connect) : l'état "ouvert" appartient au cycle de vie de la connexion.
        isOpen = false
        currentGeneration = generation

        guard let url = URL(string: urlString) else {
            NSLog("❌ Invalid WebSocket URL: %@", urlString)
            return
        }

        isConnecting = true
        let task = urlSession!.webSocketTask(with: url)
        webSocketTask = task
        task.resume()
        startListening(task: task, generation: generation)
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
    private func startListening(task: URLSessionWebSocketTask, generation: Int) {
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
                    guard let self = self, self.currentGeneration == generation else {
                        NSLog("💔 Stale WebSocket error (gen %d), ignoring", generation)
                        return
                    }
                    self.handleSocketError()
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

    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
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

    /// Événements WebSocket réellement consommés par milo-mac.
    private enum HandledEvent {
        /// Toute mise à jour d'état portant full_state (catégories "source" et
        /// "system", _FULL_STATE_CATEGORIES côté backend). L'état EQ arrive via
        /// le system/state_changed compagnon, pas via equalizer/enabled_changed.
        case systemState
        case volumeChanged
        case multiroomError
        case volumeLimitsChanged
        case dockAppsChanged
    }

    private func parseMessage(_ text: String) {
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
        let handled: HandledEvent
        switch (category, eventType) {
        case ("system", "state_changed"),
             ("system", "transition_complete"),
             ("system", "transition_start"),
             ("source", "state_changed"):
            handled = .systemState
        case ("volume", "volume_changed"):
            handled = .volumeChanged
        case ("routing", "multiroom_error"):
            handled = .multiroomError
        case ("settings", "volume_limits_changed"):
            handled = .volumeLimitsChanged
        case ("settings", "dock_apps_changed"):
            handled = .dockAppsChanged
        default:
            return
        }

        NSLog("📨 WebSocket event: %@/%@ (gen %d)", category, eventType, currentGeneration)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch handled {
            case .systemState:        self.handleSystemStateChange(eventData)
            case .volumeChanged:      self.handleVolumeChange(eventData)
            case .multiroomError:     self.delegate?.didReceiveMultiroomTransitionComplete(success: false)
            case .volumeLimitsChanged: self.handleVolumeLimitsChange(eventData)
            case .dockAppsChanged:    self.handleDockAppsChange(eventData)
            }
        }
    }

    private func handleSystemStateChange(_ data: [String: Any]) {
        guard let fullState = data["full_state"] as? [String: Any] else { return }

        delegate?.didReceiveStateUpdate(MiloState(json: fullState))

        // The backend silently pre-sets multiroom_enabled at the start of a
        // routing transition, then broadcasts many intermediate source state
        // changes that all carry the new multiroom_enabled in full_state.
        // Only the final update_multiroom_state broadcast carries the
        // multiroom_changed discriminator — treat it as the authoritative
        // completion signal for the multiroom loading spinner.
        if data["multiroom_changed"] as? Bool == true {
            delegate?.didReceiveMultiroomTransitionComplete(success: true)
        }
    }

    private func handleVolumeChange(_ data: [String: Any]) {
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
            return
        }

        let mode = state?["mode"] as? String
        let multiroomEnabled = (mode == "multiroom") || (data["multiroom_enabled"] as? Bool ?? false)

        // Les limites ne sont pas dans les événements WebSocket ;
        // elles sont préservées côté MenuBarController depuis le cache API.
        let volumeStatus = VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: multiroomEnabled,
            dspAvailable: true,
            limitMinDb: 0,
            limitMaxDb: 0
        )

        delegate?.didReceiveVolumeUpdate(volumeStatus)
    }

    // settings/volume_limits_changed → data.limits.{min_db,max_db}
    // (même enveloppe "limits" que l'ancienne route /api/settings/volume-limits)
    private func handleVolumeLimitsChange(_ data: [String: Any]) {
        guard let limits = data["limits"] as? [String: Any],
              let minDb = (limits["min_db"] as? Double) ?? (limits["min_db"] as? Int).map(Double.init),
              let maxDb = (limits["max_db"] as? Double) ?? (limits["max_db"] as? Int).map(Double.init),
              minDb < maxDb else { return }  // garde-fou : jamais de 0/0 ni de plage inversée

        delegate?.didReceiveVolumeLimitsUpdate(minDb: minDb, maxDb: maxDb)
    }

    // settings/dock_apps_changed → data.config.enabled_apps
    private func handleDockAppsChange(_ data: [String: Any]) {
        guard let config = data["config"] as? [String: Any],
              let enabledApps = config["enabled_apps"] as? [String] else { return }

        delegate?.didReceiveDockAppsUpdate(enabledApps)
    }

    // MARK: - Ping

    private func startPingTimer() {
        pingTimer?.invalidate()
        // Mode .common : le keepalive doit continuer pendant le tracking du menu
        // (le mode par défaut suspend les timers tant qu'un NSMenu est ouvert).
        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func sendPing() {
        guard isOpen else { return }

        // Capturer la génération : un ping de l'ancienne connexion dont le
        // callback d'erreur arrive après une reconnexion (sleep/wake) ne doit
        // pas détruire la nouvelle connexion, déjà ouverte.
        let generation = currentGeneration
        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                NSLog("❌ Ping failed: %@", error.localizedDescription)
                DispatchQueue.main.async {
                    guard let self = self, self.currentGeneration == generation else { return }
                    self.handleSocketError()
                }
            }
        }
    }

    deinit {
        cleanupCurrentConnection()
    }
}

// MARK: - URLSessionWebSocketDelegate
extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("✅ WebSocket connected (gen %d)", currentGeneration)

        DispatchQueue.main.async { [weak self] in
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

    func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
        NSLog("🔌 WebSocket closed (gen %d): %d - %@", currentGeneration, closeCode.rawValue, reasonString)

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.webSocketTask === task else {
                NSLog("💔 Stale WebSocket didClose callback, ignoring")
                return
            }
            self.handleSocketError()
        }
    }
}
