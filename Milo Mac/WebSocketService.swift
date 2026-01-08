import Foundation
import Network

protocol WebSocketServiceDelegate: AnyObject {
    func didReceiveStateUpdate(_ state: MiloState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
    func webSocketDidConnect()
    func webSocketDidDisconnect()
}

class WebSocketService: NSObject {
    weak var delegate: WebSocketServiceDelegate?
    
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var isConnected = false
    private var shouldReconnect = true
    private var reconnectAttempts = 0
    private let maxReconnectAttempts = 15
    private var reconnectTimer: Timer?
    
    private var host: String?
    private var port: Int = 80
    
    // NOUVEAU : Protection contre les boucles
    private var isConnecting = false
    private var lastConnectionAttempt: Date?
    private var connectionStartTime: Date?
    private let minTimeBetweenAttempts: TimeInterval = 2.0
    private let minConnectionDuration: TimeInterval = 3.0
    
    // Ping/Pong simplifié
    private var pingTimer: Timer?
    private let pingInterval: TimeInterval = 30.0  // Plus conservateur
    private var lastMessageReceived = Date()
    
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
    
    func connect(to host: String, port: Int = 80) {
        NSLog("🔌 WebSocket connect requested for \(host):\(port)")
        self.host = host
        self.port = port
        self.shouldReconnect = true
        self.reconnectAttempts = 0
        
        performConnection()
    }
    
    private func performConnection() {
        guard let host = host else {
            NSLog("❌ No host specified for WebSocket connection")
            return
        }
        
        // PROTECTION : Éviter les connexions simultanées
        if isConnecting {
            NSLog("⏸️ Connection already in progress, skipping")
            return
        }
        
        // PROTECTION : Respecter le délai minimum entre tentatives
        if let lastAttempt = lastConnectionAttempt {
            let timeSinceLastAttempt = Date().timeIntervalSince(lastAttempt)
            if timeSinceLastAttempt < minTimeBetweenAttempts {
                NSLog("⏸️ Too soon since last attempt (\(String(format: "%.1f", timeSinceLastAttempt))s), waiting...")
                DispatchQueue.main.asyncAfter(deadline: .now() + (minTimeBetweenAttempts - timeSinceLastAttempt)) { [weak self] in
                    self?.performConnection()
                }
                return
            }
        }
        
        lastConnectionAttempt = Date()
        isConnecting = true
        
        let wsPort = 8000
        let urlString = "ws://\(host):\(wsPort)/ws"
        
        guard let url = URL(string: urlString) else {
            NSLog("❌ Invalid WebSocket URL: \(urlString)")
            isConnecting = false
            scheduleReconnection()
            return
        }
        
        NSLog("🔌 Connecting to WebSocket: \(urlString) (attempt \(reconnectAttempts + 1))")
        
        // Nettoyer complètement l'ancienne connexion
        cleanupCurrentConnection()
        
        connectionStartTime = Date()
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()
        
        lastMessageReceived = Date()
        startListening()
    }
    
    private func cleanupCurrentConnection() {
        // Arrêter tous les timers
        pingTimer?.invalidate()
        pingTimer = nil
        
        // Fermer la connexion existante
        if let task = webSocketTask {
            task.cancel()
            webSocketTask = nil
        }
    }
    
    private func startListening() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleMessage(message)
                // IMPORTANT : Continuer à écouter seulement si toujours connecté
                if self?.isConnected == true {
                    self?.startListening()
                }
                
            case .failure(let error):
                NSLog("❌ WebSocket receive error: \(error)")
                DispatchQueue.main.async {
                    self?.handleDisconnection(reason: "Receive error: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func handleMessage(_ message: URLSessionWebSocketTask.Message) {
        lastMessageReceived = Date()
        
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
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            NSLog("❌ Failed to parse WebSocket message")
            return
        }
        
        NSLog("📡 WebSocket message: \(json)")
        
        if let category = json["category"] as? String,
           let eventType = json["type"] as? String,
           let eventData = json["data"] as? [String: Any] {
            
            handleMiloEvent(category: category, type: eventType, data: eventData)
        }
    }
    
    private func handleMiloEvent(category: String, type: String, data: [String: Any]) {
        DispatchQueue.main.async { [weak self] in
            switch category {
            case "system":
                if type == "state_changed" || type == "transition_complete" || type == "transition_start" {
                    self?.handleSystemStateChange(data)
                }
                
            case "volume":
                if type == "volume_changed" {
                    self?.handleVolumeChange(data)
                }
                
            case "plugin":
                if type == "state_changed" {
                    self?.handleSystemStateChange(data)
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
            pluginState: fullState["plugin_state"] as? String ?? "ready",  // "starting" déclenche le spinner
            multiroomEnabled: fullState["multiroom_enabled"] as? Bool ?? false,
            equalizerEnabled: fullState["equalizer_enabled"] as? Bool ?? false,
            metadata: fullState["metadata"] as? [String: Any] ?? [:]
        )

        delegate?.didReceiveStateUpdate(state)
    }
    
    private func handleVolumeChange(_ data: [String: Any]) {
        let volumeDb = data["volume_db"] as? Double ?? -30.0
        let multiroomEnabled = data["multiroom_enabled"] as? Bool ?? false
        let stepMobileDb = data["step_mobile_db"] as? Double ?? 3.0

        // Les limites ne sont pas transmises via WebSocket, elles sont récupérées via l'API
        // et gérées séparément par VolumeController.updateVolumeLimits()
        let volumeStatus = VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: multiroomEnabled,
            dspAvailable: true,
            limitMinDb: -80.0,  // Valeur par défaut, non utilisée (limites gérées via API)
            limitMaxDb: -21.0,  // Valeur par défaut, non utilisée (limites gérées via API)
            stepMobileDb: stepMobileDb
        )

        delegate?.didReceiveVolumeUpdate(volumeStatus)
    }
    
    private func startPingTimer() {
        pingTimer?.invalidate()
        
        pingTimer = Timer.scheduledTimer(withTimeInterval: pingInterval, repeats: true) { [weak self] _ in
            self?.sendPing()
        }
    }
    
    private func sendPing() {
        guard let webSocketTask = webSocketTask, isConnected else {
            NSLog("⚠️ Cannot ping - no connection")
            return
        }
        
        webSocketTask.sendPing { [weak self] error in
            if let error = error {
                NSLog("❌ Ping failed: \(error)")
                self?.handleDisconnection(reason: "Ping failed")
            }
        }
    }
    
    func disconnect() {
        NSLog("🔌 WebSocket manual disconnect requested")
        shouldReconnect = false
        cleanupCurrentConnection()
        
        reconnectTimer?.invalidate()
        reconnectTimer = nil
        
        if isConnected {
            isConnected = false
            isConnecting = false
            delegate?.webSocketDidDisconnect()
        }
    }
    
    private func handleDisconnection(reason: String) {
        NSLog("💔 WebSocket disconnected - \(reason)")
        
        // Calculer la durée de connexion
        var connectionDuration: TimeInterval = 0
        if let startTime = connectionStartTime {
            connectionDuration = Date().timeIntervalSince(startTime)
        }
        
        NSLog("📊 Connection lasted \(String(format: "%.1f", connectionDuration)) seconds")
        
        cleanupCurrentConnection()
        
        if isConnected {
            isConnected = false
            isConnecting = false
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.webSocketDidDisconnect()
            }
        } else {
            isConnecting = false
        }
        
        // Reconnexion seulement si nécessaire
        if shouldReconnect {
            // AMÉLIORATION : Si la connexion était très courte, augmenter le délai
            if connectionDuration < minConnectionDuration {
                NSLog("⚡ Short connection detected, increasing delay")
                reconnectAttempts += 2  // Pénalité pour connexions courtes
            } else {
                reconnectAttempts += 1
            }
            
            if reconnectAttempts < maxReconnectAttempts {
                scheduleReconnection()
            } else {
                NSLog("❌ Max reconnection attempts reached, giving up")
                shouldReconnect = false
            }
        }
    }
    
    private func scheduleReconnection() {
        reconnectTimer?.invalidate()
        
        // Délai progressif : 5, 10, 15, 20, 25, 30s max
        let delay = min(5.0 + Double(reconnectAttempts) * 5.0, 30.0)
        
        NSLog("🔄 WebSocket reconnecting in \(Int(delay)) seconds (attempt \(reconnectAttempts)/\(maxReconnectAttempts))")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            self?.performConnection()
        }
    }
    
    func forceReconnect() {
        NSLog("🔄 Force WebSocket reconnection requested")
        
        // PROTECTION : Ne pas forcer si déjà en cours de connexion
        guard !isConnecting else {
            NSLog("⏸️ Force reconnect ignored - already connecting")
            return
        }
        
        if isConnected {
            // Déconnecter proprement d'abord
            cleanupCurrentConnection()
            isConnected = false
            isConnecting = false
        }
        
        // Reconnexion immédiate
        reconnectTimer?.invalidate()
        reconnectAttempts = max(0, reconnectAttempts - 2)  // Réduire les tentatives pour force reconnect
        performConnection()
    }
    
    func getConnectionState() -> Bool {
        return isConnected
    }
    
    deinit {
        disconnect()
    }
}

// MARK: - URLSessionWebSocketDelegate
extension WebSocketService: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("✅ WebSocket connected successfully")
        
        isConnected = true
        isConnecting = false
        reconnectAttempts = 0
        
        lastMessageReceived = Date()
        startPingTimer()
        
        DispatchQueue.main.async { [weak self] in
            self?.delegate?.webSocketDidConnect()
        }
    }
    
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "No reason provided"
        NSLog("🔌 WebSocket closed with code: \(closeCode.rawValue), reason: \(reasonString)")
        
        handleDisconnection(reason: "Server closed connection (code: \(closeCode.rawValue))")
    }
}
