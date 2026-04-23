import Foundation

protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect()
    func didReceiveStateUpdate(_ state: MiloState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
    func didReceiveMultiroomTransitionComplete(success: Bool)
}

class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isOpen = false

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
        NSLog("🔌 WebSocket connecting to \(urlString) (gen \(generation))")

        cleanupCurrentConnection()
        currentGeneration = generation

        guard let url = URL(string: urlString) else {
            NSLog("❌ Invalid WebSocket URL: \(urlString)")
            return
        }

        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        startListening(generation: generation)
    }

    /// Closes the connection without notifying the delegate.
    /// Callers are responsible for managing their own state after a deliberate disconnect.
    func disconnect() {
        cleanupCurrentConnection()
        isOpen = false
    }

    func resetSession() {
        cleanupCurrentConnection()
        isOpen = false
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

    private func startListening(generation: Int) {
        webSocketTask?.receive { [weak self] result in
            guard let self = self, self.currentGeneration == generation else { return }

            switch result {
            case .success(let message):
                self.handleMessage(message)
                if self.currentGeneration == generation {
                    self.startListening(generation: generation)
                }

            case .failure(let error):
                NSLog("❌ WebSocket receive error (gen \(generation)): \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    guard let self = self, self.currentGeneration == generation else {
                        NSLog("💔 Stale WebSocket error (gen \(generation)), ignoring")
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
            delegate?.webSocketDidDisconnect()
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

    private func parseMessage(_ text: String) {
        guard let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let category = json["category"] as? String,
              let eventType = json["type"] as? String else {
            return
        }

        // Ignorer les pings du serveur (keepalive)
        if category == "system" && eventType == "ping" {
            return
        }

        NSLog("📨 WebSocket event: \(category)/\(eventType) (gen \(currentGeneration))")

        guard let eventData = json["data"] as? [String: Any] else {
            return
        }

        DispatchQueue.main.async { [weak self] in
            switch category {
            case "system":
                if eventType == "state_changed" || eventType == "transition_complete" || eventType == "transition_start" {
                    self?.handleSystemStateChange(eventData)
                }
            case "volume":
                if eventType == "volume_changed" {
                    self?.handleVolumeChange(eventData)
                }
            case "plugin":
                if eventType == "state_changed" {
                    self?.handleSystemStateChange(eventData)
                }
            case "equalizer":
                if eventType == "enabled_changed" {
                    self?.handleSystemStateChange(eventData)
                }
            case "routing":
                if eventType == "multiroom_error" {
                    self?.delegate?.didReceiveMultiroomTransitionComplete(success: false)
                }
            default:
                break
            }
        }
    }

    private func handleSystemStateChange(_ data: [String: Any]) {
        guard let fullState = data["full_state"] as? [String: Any] else { return }

        let state = MiloState(
            activeSource: fullState["active_source"] as? String ?? "none",
            sourceState: fullState["source_state"] as? String ?? "active",
            transitioning: fullState["transitioning"] as? Bool ?? false,
            multiroomEnabled: fullState["multiroom_enabled"] as? Bool ?? false,
            equalizerEnabled: fullState["equalizer_effects_enabled"] as? Bool ?? true,
            metadata: fullState["metadata"] as? [String: Any] ?? [:]
        )

        delegate?.didReceiveStateUpdate(state)

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
        let stepMobileDb = data["step_mobile_db"] as? Double ?? 3.0

        // Les limites ne sont pas dans les événements WebSocket ;
        // elles sont préservées côté MenuBarController depuis le dernier getVolumeStatus()
        let volumeStatus = VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: multiroomEnabled,
            dspAvailable: true,
            limitMinDb: 0,
            limitMaxDb: 0,
            stepMobileDb: stepMobileDb
        )

        delegate?.didReceiveVolumeUpdate(volumeStatus)
    }

    // MARK: - Ping

    private func startPingTimer() {
        pingTimer?.invalidate()
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }

    private func sendPing() {
        guard isOpen else { return }

        webSocketTask?.sendPing { [weak self] error in
            if let error = error {
                NSLog("❌ Ping failed: \(error)")
                DispatchQueue.main.async {
                    self?.handleSocketError()
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
        NSLog("✅ WebSocket connected (gen \(currentGeneration))")

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.webSocketTask === task else {
                NSLog("💔 Stale WebSocket didOpen callback, ignoring")
                return
            }
            self.isOpen = true
            self.startPingTimer()
            self.delegate?.webSocketDidConnect()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask task: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
        NSLog("🔌 WebSocket closed (gen \(currentGeneration)): \(closeCode.rawValue) - \(reasonString)")

        DispatchQueue.main.async { [weak self] in
            guard let self = self, self.webSocketTask === task else {
                NSLog("💔 Stale WebSocket didClose callback, ignoring")
                return
            }
            self.handleSocketError()
        }
    }
}
