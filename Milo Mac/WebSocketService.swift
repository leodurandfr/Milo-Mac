import Foundation
import Synchronization

/// Like MiloConnectionManagerDelegate: the callbacks are resynchronized onto the main
/// thread before being emitted (see `parseMessage`).
@MainActor
protocol WebSocketServiceDelegate: AnyObject {
    func webSocketDidConnect()
    func webSocketDidDisconnect()
    /// The connection attempt failed before the handshake completed
    /// (didOpen never received). Distinct from webSocketDidDisconnect so the
    /// connection manager can restart discovery from the .connecting phase
    /// instead of staying stuck there.
    func webSocketDidFailToConnect()
    func didReceiveStateUpdate(_ state: MiloAudioState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
    func didReceiveMultiroomTransitionComplete(success: Bool)
    /// The multiroom *structure* has changed (a client connected/disconnected, a zone was
    /// created/modified/deleted). The store re-fetches `/api/multiroom/state` rather than
    /// reapplying the wire's union diff — more robust, and the list is not large enough for
    /// the cost to matter.
    func didReceiveMultiroomStructureChanged()
    /// LIVE volume/mute per client and per zone (carried by `volume/volume_changed` in
    /// multiroom mode). Feeds the sub-section's sliders.
    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume)
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double)
    func didReceiveDockAppsUpdate(_ enabledApps: [String])
}

/// WebSocket transport: the updates pushed by the backend.
///
/// The connection state (`webSocketTask`, `isOpen`, `isConnecting`, the ping timer)
/// belongs to the **main actor** — hence `@MainActor` on the class. But URLSession delivers
/// its callbacks on ITS delegate queue: the receive loop, the ping callbacks and the
/// `URLSessionWebSocketDelegate` methods are therefore `nonisolated`, and resynchronize
/// explicitly onto the main thread. This is deliberate, and it is what the code already did.
///
/// The **generation** is the only piece of data that crosses that boundary: it is read from
/// the delegate queue to discard callbacks from a stale connection (a ping or an error from
/// the old socket, arriving after a sleep/wake reconnection, must not tear down the new
/// one). Hence the `Mutex` — where an `NSLock` asked the compiler to take our word for it,
/// this one checks.
@MainActor
final class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?

    // WebSocket
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isOpen = false
    // true between connect() and didOpen — lets a handshake failure be reported.
    private var isConnecting = false

    /// See the class header: it crosses the isolation boundary, hence the lock.
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
        // Do not depend on the caller's call order (resetSession before
        // connect): the "open" state belongs to the connection's lifecycle.
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

    /// The receive loop captures its own task: the callback (URLSession's
    /// delegate queue) never reads back self.webSocketTask, which is written
    /// on the main thread — no unsynchronized cross-reads.
    ///
    /// `nonisolated`: it runs on URLSession's delegate queue, and calls itself back from
    /// that same callback.
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
            // The handshake never completed (closed port, WS backend not ready yet):
            // without this signal the connection manager would stay in .connecting
            // forever — no other recovery path is active.
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

    /// A **decoded** event, ready to be delivered to the delegate.
    ///
    /// Sendable, and that is the whole point: decoding happens on URLSession's delegate
    /// queue, delivery on the main actor. Carrying the raw `[String: Any]` (non-Sendable)
    /// across would mean lying to the compiler; so we carry the typed result across, which
    /// also moves all the parsing off the main thread.
    private enum DecodedEvent: Sendable {
        /// `source/state`: the complete audio state, published on every change of any of its
        /// fields and only then. It carries the EQ and multiroom flags too, so neither
        /// equalizer/enabled_changed nor a multiroom discriminator is needed.
        case state(MiloAudioState)
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

        // The backend broadcasts to ALL clients: milo-mac therefore also receives
        // plenty of events meant for the web frontend
        // (settings/fan_status_changed, settings/bt_remote_status_changed,
        // settings/mac_roc_changed, routing/multiroom_ready, equalizer/levels,
        // system/ping…) that it does not consume. We log and handle ONLY the
        // useful events — the rest is ignored silently, with no main-thread hop.
        let decoded: DecodedEvent?
        switch (category, eventType) {
        case ("source", "state"):
            decoded = Self.decodeState(eventData)
        case ("volume", "volume_changed"):
            decoded = Self.decodeVolume(eventData)
        case ("routing", "multiroom_error"):
            decoded = .multiroomFailed
        case ("multiroom", "client_state_changed"),
             ("multiroom", "zone_changed"):
            // A single signal on the store side: the structure moved, re-fetch. We do not
            // distinguish client from zone — the re-fetch covers both.
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
        case .state(let state):
            // The end of a multiroom switch is not an event of its own any more: it is the
            // first state where `switching` is false again, which the store resolves.
            delegate?.didReceiveStateUpdate(state)

        case .volume(let volume, let multiroom):
            delegate?.didReceiveVolumeUpdate(volume)
            // In multiroom mode, the same event carries the per-client and per-zone
            // volume/mute (`state.clients` / `state.zones`) — the LIVE source of the
            // sub-section's sliders.
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

    // MARK: - Decoding (off the main thread)

    /// The event's `data` IS the state. Re-serialized so it goes through the one shared
    /// decoder, exactly like the HTTP fetch — the two transports cannot diverge. A state this
    /// build cannot read (an unknown `service` or `phase`) is dropped and logged: it is a
    /// contract mismatch with the backend, not something to guess around.
    private nonisolated static func decodeState(_ data: [String: Any]) -> DecodedEvent? {
        do {
            let raw = try JSONSerialization.data(withJSONObject: data)
            return .state(try MiloAudioState.decode(raw))
        } catch {
            NSLog("❌ source/state not decodable: %@", String(describing: error))
            return nil
        }
    }

    private nonisolated static func decodeVolume(_ data: [String: Any]) -> DecodedEvent? {
        let volumeDb: Double
        let state = data["state"] as? [String: Any]

        // The new format takes priority (state.global_volume_db)
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

        // Per-client and per-zone volume/mute: only in multiroom mode, and only if there
        // really are clients/zones (otherwise nil, so we do not wake the store for nothing).
        let multiroom: MultiroomVolume?
        if let state, mode == "multiroom" {
            let mv = MultiroomVolume(state: state)
            multiroom = (mv.clients.isEmpty && mv.zones.isEmpty) ? nil : mv
        } else {
            multiroom = nil
        }

        // The limits are not in the WebSocket events; they are preserved from the API cache
        // by `MiloStore.didReceiveVolumeUpdate`.
        return .volume(VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: multiroomEnabled,
            limitMinDb: 0,
            limitMaxDb: 0
        ), multiroom: multiroom)
    }

    // settings/volume_limits_changed → data.limits.{min_db,max_db}
    // (the same "limits" envelope as the old /api/settings/volume-limits route)
    private nonisolated static func decodeVolumeLimits(_ data: [String: Any]) -> DecodedEvent? {
        guard let limits = data["limits"] as? [String: Any],
              let minDb = (limits["min_db"] as? Double) ?? (limits["min_db"] as? Int).map(Double.init),
              let maxDb = (limits["max_db"] as? Double) ?? (limits["max_db"] as? Int).map(Double.init),
              minDb < maxDb else { return nil }  // guard rail: never 0/0, never an inverted range

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
        // .common mode: the keepalive has to survive mouse tracking — dragging the slider
        // or scrolling the station list flips the run loop into `.eventTracking`, where a
        // timer scheduled in the default mode alone would stop firing.
        let timer = Timer(timeInterval: pingInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sendPing() }
        }
        RunLoop.main.add(timer, forMode: .common)
        pingTimer = timer
    }

    private func sendPing() {
        guard isOpen else { return }

        // Capture the generation: a ping from the old connection whose error
        // callback arrives after a reconnection (sleep/wake) must not tear down
        // the new connection, already open.
        let pingGeneration = currentGeneration
        webSocketTask?.sendPing { [weak self] error in
            // Callback delivered on URLSession's delegate queue.
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

/// Delivered on URLSession's delegate queue, hence `nonisolated`: each one
/// resynchronizes onto the main thread, where the connection state lives.
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
