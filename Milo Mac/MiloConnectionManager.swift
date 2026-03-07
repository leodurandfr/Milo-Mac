import Foundation
import Network
import AppKit

// MARK: - Connection Phase State Machine
enum ConnectionPhase: Equatable, CustomStringConvertible {
    /// Not trying to connect. Entry: stop() called.
    case idle
    /// mDNS browser is active, waiting for milo.local to appear.
    case discovering
    /// mDNS found milo.local, running rapid API health checks.
    case testingAPI(attempt: Int)
    /// WebSocket handshake in progress (task resumed, waiting for didOpen).
    case connecting
    /// Fully connected, WebSocket open, events flowing.
    case connected

    var isConnected: Bool {
        if case .connected = self { return true }
        return false
    }

    var description: String {
        switch self {
        case .idle: return "idle"
        case .discovering: return "discovering"
        case .testingAPI(let attempt): return "testingAPI(\(attempt))"
        case .connecting: return "connecting"
        case .connected: return "connected"
        }
    }
}

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

    // State machine
    private var phase: ConnectionPhase = .idle {
        didSet { NSLog("🔄 Connection phase: \(oldValue) → \(phase)") }
    }
    private var connectionGeneration: Int = 0

    // Services
    private let webSocketService = WebSocketService()
    private var apiService: MiloAPIService?

    // mDNS/Bonjour Discovery
    private var serviceBrowser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []

    // Retry ciblé (quand mDNS trouve le Pi)
    private var retryTimer: Timer?
    private var retryCount = 0
    private let maxRetries = 20
    private let retryInterval: TimeInterval = 2.0

    override init() {
        super.init()
        webSocketService.delegate = self
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
    }

    @objc private func systemDidWake() {
        NSLog("☀️ System woke up - forcing reconnection...")

        DispatchQueue.global(qos: .default).async { [weak self] in
            guard let self = self else { return }

            // Give the network stack a moment to stabilize after wake
            Thread.sleep(forTimeInterval: 1.0)

            DispatchQueue.main.async {
                guard self.phase != .idle else { return }

                let wasConnected = self.phase.isConnected

                self.webSocketService.disconnect()
                self.webSocketService.resetSession()
                self.stopRetry()
                self.stopDiscovery()
                self.apiService = nil

                if wasConnected {
                    self.delegate?.miloDidDisconnect()
                }

                self.phase = .discovering
                NSLog("🔄 Network stabilized - starting fresh mDNS discovery...")
                self.startDiscovery()
            }
        }
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
        phase = .discovering
        startDiscovery()
    }

    func stop() {
        NSLog("🛑 MiloConnectionManager stopping...")
        let wasConnected = phase.isConnected

        phase = .idle
        stopDiscovery()
        stopRetry()
        webSocketService.disconnect()
        apiService = nil

        if wasConnected {
            DispatchQueue.main.async { [weak self] in
                self?.delegate?.miloDidDisconnect()
            }
        }
    }

    func getAPIService() -> MiloAPIService? {
        return apiService
    }

    func isCurrentlyConnected() -> Bool {
        return phase.isConnected
    }

    func forceReconnect() {
        guard case .connected = phase else { return }

        NSLog("🔄 Forcing reconnection to clear stale state...")
        handleDisconnection()
    }

    // MARK: - mDNS Discovery

    private func startDiscovery() {
        guard case .discovering = phase, serviceBrowser == nil else { return }

        NSLog("📡 Starting mDNS discovery for milo.local...")

        serviceBrowser = NetServiceBrowser()
        serviceBrowser?.delegate = self
        serviceBrowser?.searchForServices(ofType: "_http._tcp", inDomain: "local.")
    }

    private func stopDiscovery() {
        NSLog("🛑 Stopping mDNS discovery")

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
        guard case .discovering = phase else { return }

        NSLog("🔄 Milo detected - starting 20 rapid API tests...")

        stopDiscovery()

        retryCount = 0
        phase = .testingAPI(attempt: 0)

        retryTimer = Timer.scheduledTimer(withTimeInterval: retryInterval, repeats: true) { [weak self] _ in
            self?.testAPIWithRetry()
        }
        retryTimer?.fire()
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
    }

    private func testAPIWithRetry() {
        guard case .testingAPI = phase else { return }

        retryCount += 1
        phase = .testingAPI(attempt: retryCount)
        NSLog("🔍 API test \(retryCount)/\(maxRetries)...")

        Task { @MainActor [weak self] in
            guard let self = self else { return }
            guard case .testingAPI = self.phase else { return }

            do {
                let testAPI = MiloAPIService(host: self.host, port: self.httpPort)
                _ = try await testAPI.fetchState()

                guard case .testingAPI = self.phase else { return }
                NSLog("✅ API ready after \(self.retryCount) attempts!")
                await self.connectToMilo()

            } catch {
                guard case .testingAPI = self.phase else { return }
                NSLog("❌ API test \(self.retryCount) failed: \(error.localizedDescription)")

                if self.retryCount >= self.maxRetries {
                    NSLog("🚫 20 attempts failed - resuming mDNS discovery...")
                    self.resumeDiscoveryAfterFailure()
                }
            }
        }
    }

    private func resumeDiscoveryAfterFailure() {
        stopRetry()
        phase = .discovering
        startDiscovery()
    }

    // MARK: - Connection

    @MainActor
    private func connectToMilo() async {
        guard case .testingAPI = phase else { return }

        connectionGeneration += 1
        let myGeneration = connectionGeneration

        NSLog("🔌 Connecting to Milo (gen \(myGeneration))...")

        stopRetry()
        phase = .connecting

        // Résoudre l'IP IPv4 AVANT de connecter
        await Task.detached(priority: .medium) { [weak self] in
            self?.resolveIPv4Address()
        }.value

        // Vérifier qu'on est toujours en phase connecting
        guard case .connecting = phase, connectionGeneration == myGeneration else { return }

        let hostToUse = resolvedIPv4 ?? host
        let urlString = "ws://\(hostToUse):\(wsPort)/ws"

        webSocketService.resetSession()
        webSocketService.connect(to: urlString, generation: myGeneration)
    }

    private func handleConnectionSuccess() {
        NSLog("🎉 Milo connected successfully!")

        phase = .connected
        apiService = MiloAPIService(host: host, port: httpPort)
        delegate?.miloDidConnect()
    }

    private func handleDisconnection() {
        NSLog("💔 Milo connection lost")

        let wasConnected = phase.isConnected

        webSocketService.disconnect()
        stopRetry()
        stopDiscovery()
        apiService = nil
        phase = .discovering

        if wasConnected {
            delegate?.miloDidDisconnect()
        }

        startDiscovery()
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stop()
    }
}

// MARK: - WebSocketServiceDelegate
extension MiloConnectionManager: WebSocketServiceDelegate {
    func webSocketDidConnect() {
        handleConnectionSuccess()
    }

    func webSocketDidDisconnect() {
        handleDisconnection()
    }

    func didReceiveStateUpdate(_ state: MiloState) {
        delegate?.didReceiveStateUpdate(state)
    }

    func didReceiveVolumeUpdate(_ volume: VolumeStatus) {
        delegate?.didReceiveVolumeUpdate(volume)
    }
}

// MARK: - NetServiceBrowserDelegate
extension MiloConnectionManager: NetServiceBrowserDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("🔍 Found service: \(service.name) (type: \(service.type), domain: \(service.domain))")

        guard case .discovering = phase else { return }

        service.delegate = self
        resolvingServices.insert(service)
        service.resolve(withTimeout: 5.0)
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        NSLog("📤 Service removed: \(service.name)")

        let serviceName = service.name.lowercased()
        let hostName = service.hostName?.lowercased() ?? ""

        guard serviceName.contains("milo") || hostName.contains("milo") else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            switch self.phase {
            case .testingAPI:
                NSLog("📡 Milo service removed during retry - resuming discovery...")
                self.stopRetry()
                self.phase = .discovering
                self.startDiscovery()
            case .connecting, .connected:
                self.handleDisconnection()
            default:
                break
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

        resolvingServices.remove(sender)

        guard case .discovering = phase else {
            NSLog("⏭️  Skipping - not in discovering phase")
            return
        }

        let cleanedHostname = hostName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if cleanedHostname == "milo.local" {
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
