import Foundation
import Network
import AppKit

protocol MiloConnectionManagerDelegate: AnyObject {
    func miloDidConnect()
    func miloDidDisconnect()
    func didReceiveStateUpdate(_ state: MiloState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
}

class MiloConnectionManager: NSObject {
    weak var delegate: MiloConnectionManagerDelegate?

    // Référence vers RocVADManager pour mettre à jour l'endpoint avec l'IP résolue
    var rocVADManager: RocVADManager?

    // Configuration
    private let host = "milo.local"
    private let httpPort = 80
    private let wsPort = 8000
    private var resolvedIPv4: String?

    // État simple
    private var isConnected = false
    private var shouldConnect = true
    
    // Services
    private var webSocketTask: URLSessionWebSocketTask?
    private var urlSession: URLSession?
    private var apiService: MiloAPIService?
    
    // mDNS/Bonjour Discovery
    private var serviceBrowser: NetServiceBrowser?
    private var isDiscovering = false
    private var resolvingServices: Set<NetService> = []
    
    // Retry ciblé (quand mDNS trouve le Pi)
    private var retryTimer: Timer?
    private var retryCount = 0
    private var isRetrying = false  // Protection contre retry multiples
    private let maxRetries = 20
    private let retryInterval: TimeInterval = 2.0
    
    override init() {
        super.init()
        setupURLSession()
        setupSleepWakeNotifications()
    }

    private func setupSleepWakeNotifications() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemWillSleep),
            name: NSWorkspace.willSleepNotification,
            object: nil
        )

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSLog("💤 Sleep/wake notifications registered")
    }

    @objc private func systemWillSleep() {
        NSLog("💤 System going to sleep - preparing for sleep...")
        // Don't disconnect here - let the system handle it naturally
        // We'll reconnect on wake
    }

    @objc private func systemDidWake() {
        NSLog("☀️ System woke up - forcing reconnection...")

        // Use DispatchQueue to avoid priority inversion
        DispatchQueue.global(qos: .default).async { [weak self] in
            guard let self = self, self.shouldConnect else { return }

            // Give the network stack a moment to stabilize after wake
            Thread.sleep(forTimeInterval: 1.0)

            DispatchQueue.main.async {
                // Clean up existing connection
                self.cleanupConnection()
                self.isConnected = false

                // Reset URLSession to clear any stale TCP connections
                self.resetURLSession()

                // Stop any ongoing retry attempts
                self.stopRetry()

                NSLog("🔄 Network stabilized - starting fresh mDNS discovery...")
                self.startDiscovery()
            }
        }
    }
    
    private func setupURLSession() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 5.0
        config.timeoutIntervalForResource = 30.0
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }

    private func resetURLSession() {
        urlSession?.invalidateAndCancel()
        setupURLSession()
        NSLog("🔄 URLSession reset to clear stale connections")
    }

    /// Résout le hostname en IPv4, teste la latence de toutes les IPs et sélectionne la meilleure
    private func resolveIPv4Address() {
        let cfHost = CFHostCreateWithName(nil, self.host as CFString).takeRetainedValue()
        CFHostStartInfoResolution(cfHost, .addresses, nil)

        var allIPv4: [String] = []

        var success: DarwinBoolean = false
        if let addresses = CFHostGetAddressing(cfHost, &success)?.takeUnretainedValue() as NSArray? {
            for case let address as NSData in addresses {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address.bytes.assumingMemoryBound(to: sockaddr.self),
                             socklen_t(address.length),
                             &hostname,
                             socklen_t(hostname.count),
                             nil, 0, NI_NUMERICHOST) == 0 {
                    let ipAddress = String(cString: hostname)
                    // Ne garder que les IPv4 (pas d'IPv6 avec ":")
                    if !ipAddress.contains(":") {
                        allIPv4.append(ipAddress)
                        NSLog("📍 Found IPv4: \(ipAddress)")
                    }
                }
            }
        }

        // Si plusieurs IPs trouvées, sélectionner la meilleure par latence
        if allIPv4.count > 1 {
            selectBestIP(from: allIPv4)
        } else if let firstIP = allIPv4.first {
            resolvedIPv4 = firstIP
            NSLog("✅ Resolved \(self.host) to IPv4: \(firstIP)")
            // Mettre à jour roc-vad avec l'IP résolue
            rocVADManager?.updateMiloHost(firstIP)
        }
    }

    /// Sélectionne la meilleure IP parmi plusieurs candidats en testant la latence
    private func selectBestIP(from candidates: [String]) {
        NSLog("🔄 Testing latency for \(candidates.count) IP candidates...")

        let group = DispatchGroup()
        var results: [(ip: String, latency: TimeInterval)] = []
        let resultsLock = NSLock()

        for ip in candidates {
            group.enter()
            measureLatency(to: ip) { latency in
                if let latency = latency {
                    resultsLock.lock()
                    results.append((ip, latency))
                    resultsLock.unlock()
                    NSLog("📊 Latency to \(ip): \(String(format: "%.1f", latency * 1000))ms")
                } else {
                    NSLog("⚠️ Failed to measure latency to \(ip)")
                }
                group.leave()
            }
        }

        // Attendre tous les résultats (max 2 secondes)
        let waitResult = group.wait(timeout: .now() + 2.0)

        if waitResult == .timedOut {
            NSLog("⚠️ Latency test timed out, using first available IP")
        }

        // Sélectionner l'IP avec la meilleure latence
        if let best = results.min(by: { $0.latency < $1.latency }) {
            resolvedIPv4 = best.ip
            NSLog("✅ Selected best IP: \(best.ip) (\(String(format: "%.1f", best.latency * 1000))ms)")
            // Mettre à jour roc-vad avec l'IP la plus rapide
            rocVADManager?.updateMiloHost(best.ip)
        } else if let firstIP = candidates.first {
            resolvedIPv4 = firstIP
            NSLog("✅ Fallback to first IP: \(firstIP)")
            rocVADManager?.updateMiloHost(firstIP)
        }
    }

    /// Mesure la latence vers une IP via une connexion TCP rapide
    private func measureLatency(to ip: String, completion: @escaping (TimeInterval?) -> Void) {
        let start = Date()

        let connection = NWConnection(
            host: NWEndpoint.Host(ip),
            port: NWEndpoint.Port(integerLiteral: UInt16(httpPort)),
            using: .tcp
        )

        var hasCompleted = false
        let completionLock = NSLock()

        connection.stateUpdateHandler = { state in
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                return
            }

            switch state {
            case .ready:
                hasCompleted = true
                completionLock.unlock()
                let latency = Date().timeIntervalSince(start)
                connection.cancel()
                completion(latency)

            case .failed, .cancelled:
                hasCompleted = true
                completionLock.unlock()
                completion(nil)

            default:
                completionLock.unlock()
            }
        }

        connection.start(queue: .global(qos: .userInitiated))

        // Timeout de 500ms
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            completionLock.lock()
            guard !hasCompleted else {
                completionLock.unlock()
                return
            }
            hasCompleted = true
            completionLock.unlock()
            connection.cancel()
            completion(nil)
        }
    }
    
    // MARK: - Public Interface
    
    func start() {
        NSLog("🎯 MiloConnectionManager starting with mDNS + retry...")
        shouldConnect = true
        startDiscovery()
    }
    
    func stop() {
        NSLog("🛑 MiloConnectionManager stopping...")
        shouldConnect = false
        stopDiscovery()
        stopRetry()
        disconnect()
    }
    
    func getAPIService() -> MiloAPIService? {
        return apiService
    }
    
    func isCurrentlyConnected() -> Bool {
        return isConnected
    }

    func forceReconnect() {
        guard isConnected else { return }

        NSLog("🔄 Forcing reconnection to clear stale state...")
        Task { @MainActor in
            handleDisconnection()
        }
    }
    
    // MARK: - mDNS Discovery
    
    private func startDiscovery() {
        guard shouldConnect && !isDiscovering else { return }
        
        NSLog("📡 Starting mDNS discovery for milo.local...")
        isDiscovering = true
        
        serviceBrowser = NetServiceBrowser()
        serviceBrowser?.delegate = self
        serviceBrowser?.searchForServices(ofType: "_http._tcp", inDomain: "local.")
    }
    
    private func stopDiscovery() {
        NSLog("🛑 Stopping mDNS discovery")
        isDiscovering = false

        // Arrêter tous les services en cours de résolution
        for service in resolvingServices {
            service.stop()
            service.delegate = nil
        }
        resolvingServices.removeAll()

        serviceBrowser?.stop()
        serviceBrowser?.delegate = nil
        serviceBrowser = nil
    }
    
    // MARK: - Retry ciblé (quand mDNS trouve Milo)
    
    private func startAPIRetry() {
        // Protection contre retry multiples
        guard !isRetrying && !isConnected else { return }
        
        NSLog("🔄 Milo detected - starting 20 rapid API tests...")
        
        // Arrêter mDNS pendant les retry
        stopDiscovery()
        
        isRetrying = true
        retryCount = 0
        testAPIWithRetry()
        
        // Programmer les retry suivants
        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            self?.testAPIWithRetry()
        }
    }
    
    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        isRetrying = false
    }
    
    private func testAPIWithRetry() {
        retryCount += 1
        NSLog("🔍 API test \(retryCount)/\(maxRetries)...")
        
        Task {
            do {
                let testAPI = MiloAPIService(host: host, port: httpPort)
                _ = try await testAPI.fetchState()
                
                NSLog("✅ API ready after \(retryCount) attempts!")
                await connectToMilo()
                
            } catch {
                NSLog("❌ API test \(retryCount) failed: \(error.localizedDescription)")
                
                if retryCount >= maxRetries {
                    NSLog("🚫 20 attempts failed - resuming mDNS discovery...")
                    await resumeDiscoveryAfterFailure()
                }
            }
        }
    }
    
    @MainActor
    private func resumeDiscoveryAfterFailure() {
        stopRetry()
        
        // Reprendre mDNS discovery
        if shouldConnect && !isConnected {
            startDiscovery()
        }
    }
    
    // MARK: - Connection
    
    @MainActor
    private func connectToMilo() async {
        guard shouldConnect && !isConnected else { return }

        NSLog("🔌 Connecting to Milo...")

        // Arrêter retry - on a trouvé Milo !
        stopRetry()

        // Reset URLSession pour éviter les connexions TCP stales
        resetURLSession()

        // Résoudre l'IP IPv4 AVANT de connecter (synchrone pour garantir qu'on a l'IP)
        // Utiliser .medium QoS pour éviter priority inversion avec les appels DNS système
        await Task.detached(priority: .medium) { [weak self] in
            self?.resolveIPv4Address()
        }.value

        // Connecter WebSocket avec l'IP résolue
        await connectWebSocket()
    }
    
    private func connectWebSocket() async {
        // Utiliser l'IP IPv4 si disponible pour éviter les timeouts DNS
        let hostToUse = resolvedIPv4 ?? host
        let urlString = "ws://\(hostToUse):\(wsPort)/ws"
        guard let url = URL(string: urlString) else {
            NSLog("❌ Invalid WebSocket URL")
            return
        }

        // Nettoyer l'ancienne connexion
        cleanupConnection()

        NSLog("🌐 Connecting WebSocket to \(urlString)...")
        webSocketTask = urlSession?.webSocketTask(with: url)
        webSocketTask?.resume()

        startListening()
    }
    
    private func cleanupConnection() {
        webSocketTask?.cancel()
        webSocketTask = nil
        apiService = nil
    }
    
    private func startListening() {
        webSocketTask?.receive { [weak self] result in
            switch result {
            case .success(let message):
                self?.handleWebSocketMessage(message)
                // Continuer à écouter si toujours connecté
                if self?.isConnected == true {
                    self?.startListening()
                }
                
            case .failure(let error):
                NSLog("❌ WebSocket error: \(error.localizedDescription)")
                DispatchQueue.main.async { [weak self] in
                    self?.handleDisconnection()
                }
            }
        }
    }
    
    private func handleWebSocketMessage(_ message: URLSessionWebSocketTask.Message) {
        switch message {
        case .string(let text):
            parseWebSocketMessage(text)
        case .data(let data):
            if let text = String(data: data, encoding: .utf8) {
                parseWebSocketMessage(text)
            }
        @unknown default:
            break
        }
    }
    
    private func parseWebSocketMessage(_ text: String) {
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

            default:
                break
            }
        }
    }
    
    private func handleSystemStateChange(_ data: [String: Any]) {
        guard let fullState = data["full_state"] as? [String: Any] else { return }
        
        // CORRECTION : Ajout du paramètre targetSource manquant
        let targetSource = fullState["target_source"] as? String
        
        let state = MiloState(
            activeSource: fullState["active_source"] as? String ?? "none",
            pluginState: fullState["plugin_state"] as? String ?? "inactive",
            isTransitioning: fullState["transitioning"] as? Bool ?? false,
            targetSource: targetSource, // AJOUTÉ
            multiroomEnabled: fullState["multiroom_enabled"] as? Bool ?? false,
            equalizerEnabled: fullState["equalizer_enabled"] as? Bool ?? false,
            metadata: fullState["metadata"] as? [String: Any] ?? [:]
        )
        
        delegate?.didReceiveStateUpdate(state)
    }
    
    private func handleVolumeChange(_ data: [String: Any]) {
        let volume = data["volume"] as? Int ?? 0
        let mode = data["mode"] as? String ?? "unknown"
        let multiroomEnabled = data["multiroom_enabled"] as? Bool ?? false
        
        let volumeStatus = VolumeStatus(
            volume: volume,
            mode: mode,
            multiroomEnabled: multiroomEnabled
        )
        
        delegate?.didReceiveVolumeUpdate(volumeStatus)
    }
    
    private func handleConnectionSuccess() {
        NSLog("🎉 Milo connected successfully!")

        isConnected = true

        // Créer un nouveau API service avec session fraîche
        apiService = MiloAPIService(host: host, port: httpPort)

        delegate?.miloDidConnect()
    }
    
    private func handleDisconnection() {
        NSLog("💔 Milo connection lost")
        
        cleanupConnection()
        
        if isConnected {
            isConnected = false
            delegate?.miloDidDisconnect()
        }
        
        // Reprendre mDNS discovery pour détecter quand Milo revient
        if shouldConnect {
            NSLog("📡 Resuming mDNS discovery...")
            startDiscovery()
        }
    }
    
    private func disconnect() {
        cleanupConnection()
        
        if isConnected {
            isConnected = false
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.miloDidDisconnect()
            }
        }
    }
    
    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stop()
    }
}

// MARK: - NetServiceBrowserDelegate
extension MiloConnectionManager: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("🔍 Found service: \(service.name) (type: \(service.type), domain: \(service.domain))")

        // Ne pas traiter si déjà en train de retry ou connecté
        guard !isRetrying && !isConnected else { return }

        // Résoudre le service pour obtenir son vrai hostname
        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        NSLog("📤 Service removed: \(service.name)")
        
        let serviceName = service.name.lowercased()
        let hostName = service.hostName?.lowercased() ?? ""
        
        if serviceName.contains("milo") || hostName.contains("milo") {
            // Arrêter retry si on était en train de tester
            if retryTimer != nil {
                NSLog("📡 Milo service removed during retry - resuming discovery...")
                stopRetry()
                if shouldConnect && !isConnected {
                    startDiscovery()
                }
            }
            
            // Gérer la déconnexion si on était connecté
            if isConnected {
                DispatchQueue.main.async { [weak self] in
                    self?.handleDisconnection()
                }
            }
        }
    }
    
    func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        NSLog("📡 mDNS browser will start searching...")
    }
    
    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        NSLog("🛑 mDNS browser stopped searching")
    }
    
    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        NSLog("❌ mDNS browser search failed: \(errorDict)")
    }
}

// MARK: - NetServiceDelegate
extension MiloConnectionManager: NetServiceDelegate {
    func netServiceDidResolveAddress(_ sender: NetService) {
        let hostName = sender.hostName ?? ""
        NSLog("✅ Service resolved: \(sender.name) -> hostname: \(hostName)")

        // Nettoyer le service du set de résolution
        resolvingServices.remove(sender)

        // Vérifier que c'est EXACTEMENT milo.local (ou milo.local.)
        let cleanedHostname = hostName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleanedHostname == "milo.local" && !isRetrying && !isConnected {
            NSLog("🎯 Confirmed Milo service (hostname: \(hostName)) - starting rapid API tests...")
            startAPIRetry()
        } else {
            NSLog("⏭️  Skipping service \(sender.name) (hostname: \(hostName)) - not milo.local")
        }
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        NSLog("⚠️ Failed to resolve service \(sender.name): \(errorDict)")
        resolvingServices.remove(sender)
    }
}

// MARK: - URLSessionWebSocketDelegate
extension MiloConnectionManager: URLSessionWebSocketDelegate {
    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didOpenWithProtocol protocol: String?) {
        NSLog("✅ WebSocket connected")

        DispatchQueue.main.async { [weak self] in
            self?.handleConnectionSuccess()
        }
    }

    func urlSession(_ session: URLSession, webSocketTask: URLSessionWebSocketTask, didCloseWith closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        let reasonString = reason.flatMap { String(data: $0, encoding: .utf8) } ?? "Unknown"
        NSLog("🔌 WebSocket closed: \(closeCode.rawValue) - \(reasonString)")

        DispatchQueue.main.async { [weak self] in
            self?.handleDisconnection()
        }
    }
}
