import Foundation
import Network
import AppKit
import Synchronization

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

/// Tous les rappels sont livrés sur le main thread — c'était déjà le cas, ce n'est
/// maintenant plus une convention mais une signature.
///
/// `Sendable` : le delegate est parfois extrait puis relâché sur la main queue (voir
/// `stop()`, appelé depuis `deinit`). Ses conformants sont des classes `@MainActor`, donc
/// Sendable de plein droit.
@MainActor
protocol MiloConnectionManagerDelegate: AnyObject, Sendable {
    func miloDidConnect()
    func miloDidDisconnect()
    func didReceiveStateUpdate(_ state: MiloState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
    func didReceiveMultiroomTransitionComplete(success: Bool)
    func didReceiveMultiroomStructureChanged()
    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume)
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double)
    func didReceiveDockAppsUpdate(_ enabledApps: [String])
}

/// Découverte et connexion à Milō : mDNS → tests de readiness de l'API → WebSocket.
///
/// Main-thread-only, désormais vérifié. La machine à phases, l'état de découverte et les
/// timers appartiennent au main actor ; seuls les travaux réellement bloquants (résolution
/// CFHost, sondes TCP de latence) partent hors du main thread — et le font par `await`,
/// donc en revenant tout seuls.
@MainActor
final class MiloConnectionManager: NSObject {
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
        didSet { NSLog("🔄 Connection phase: %@ → %@", oldValue.description, phase.description) }
    }
    private var connectionGeneration: Int = 0

    // Services
    private let webSocketService = WebSocketService()
    /// Service HTTP de la connexion active. Créé à la connexion, nil sinon.
    private(set) var apiService: MiloAPIService?
    /// Instance unique réutilisée pour les 20 tests de readiness — en créer une
    /// par tentative laissait fuiter deux URLSessions toutes les 2 secondes.
    private var probeAPIService: MiloAPIService?

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
            selector: #selector(systemDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil
        )

        NSLog("💤 Wake notification registered")
    }

    /// Livré par NSWorkspace sur le main thread.
    @objc private nonisolated func systemDidWake() {
        NSLog("☀️ System woke up - forcing reconnection...")

        Task { @MainActor [weak self] in
            // Laisser la pile réseau se stabiliser après le réveil.
            try? await Task.sleep(for: .seconds(1))

            guard let self, self.phase != .idle else { return }

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

    /// Résout le hostname en IPv4 et, s'il y a plusieurs candidats, retient le plus rapide.
    ///
    /// `nonisolated` : `IPv4Resolver.resolveAll` (CFHost) bloque, et les sondes TCP prennent
    /// jusqu'à 500 ms chacune — rien de tout ça n'a sa place sur le main actor. L'appelant
    /// n'a qu'à `await`, et récupère la main tout seul.
    ///
    /// La résolution est explicitement poussée sur une queue `.utility` : cette méthode est
    /// appelée depuis `connectToMilo()` sur le main actor, donc le pool coopératif de la
    /// concurrence structurée hérite d'une QoS `.userInitiated`. `CFHostStartInfoResolution`
    /// bloque le thread appelant en attendant une réponse résolue en interne à une QoS
    /// `.default` — sans ce hop, un thread `.userInitiated` attend sur un thread `.default`,
    /// l'inversion de priorité qu'Instruments signale ("Hang Risk"). `.utility` (< `.default`)
    /// fait de l'attente une simple donation de priorité descendante, pas une inversion.
    private nonisolated static func resolveBestIPv4(host: String, port: Int) async -> String? {
        let candidates = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: IPv4Resolver.resolveAll(host: host))
            }
        }
        for ip in candidates {
            NSLog("📍 Found IPv4: %@", ip)
        }

        guard candidates.count > 1 else { return candidates.first }

        NSLog("🔄 Testing latency for %d IP candidates...", candidates.count)

        // Les sondes courent en parallèle et se bornent elles-mêmes à 500 ms : le
        // `DispatchGroup.wait(timeout:)` global d'avant n'a plus lieu d'être.
        var results: [(ip: String, latency: TimeInterval)] = []
        await withTaskGroup(of: (String, TimeInterval?).self) { group in
            for ip in candidates {
                group.addTask { (ip, await measureLatency(to: ip, port: port)) }
            }
            for await (ip, latency) in group {
                guard let latency else {
                    NSLog("⚠️ Failed to measure latency to %@", ip)
                    continue
                }
                results.append((ip, latency))
                NSLog("📊 Latency to %@: %.1fms", ip, latency * 1000)
            }
        }

        if let best = results.min(by: { $0.latency < $1.latency }) {
            NSLog("✅ Selected best IP: %@ (%.1fms)", best.ip, best.latency * 1000)
            return best.ip
        }

        NSLog("⚠️ No latency measured, falling back to first IP")
        return candidates.first
    }

    /// Mesure la latence vers une IP via une connexion TCP rapide.
    ///
    /// La continuation ne doit être reprise **qu'une fois**, alors que le handler d'état et
    /// le timeout de 500 ms courent en parallèle : d'où le drapeau sous verrou. C'était un
    /// `var hasCompleted` + NSLock, que le compilateur ne pouvait pas suivre ; un `Mutex`
    /// dit la même chose, et se prouve.
    private nonisolated static func measureLatency(to ip: String, port: Int) async -> TimeInterval? {
        await withCheckedContinuation { continuation in
            let start = Date()
            let connection = NWConnection(
                host: NWEndpoint.Host(ip),
                port: NWEndpoint.Port(integerLiteral: UInt16(port)),
                using: .tcp
            )

            let hasCompleted = Mutex(false)
            let finish: @Sendable (TimeInterval?) -> Void = { latency in
                let alreadyDone = hasCompleted.withLock { done in
                    defer { done = true }
                    return done
                }
                guard !alreadyDone else { return }
                connection.cancel()
                continuation.resume(returning: latency)
            }

            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:              finish(Date().timeIntervalSince(start))
                case .failed, .cancelled: finish(nil)
                default:                  break
                }
            }

            connection.start(queue: .global(qos: .userInitiated))

            // Timeout de 500 ms
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) { finish(nil) }
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
            // Capturer le delegate plutôt que `self` : stop() est aussi appelé depuis
            // deinit, et former une référence faible sur un objet en cours de
            // désallocation fait crasher le runtime objc.
            let delegate = self.delegate
            DispatchQueue.main.async {
                MainActor.assumeIsolated { delegate?.miloDidDisconnect() }
            }
        }
    }

    var isConnected: Bool {
        return phase.isConnected
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

        NSLog("🔄 Milo detected - starting %d rapid API tests...", maxRetries)

        stopDiscovery()

        retryCount = 0
        phase = .testingAPI(attempt: 0)
        probeAPIService = MiloAPIService(host: host, port: httpPort)

        // Mode .common : continuer les tests même si l'utilisateur garde le menu
        // ouvert (le mode par défaut suspend les timers pendant le tracking).
        let timer = Timer(timeInterval: retryInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.testAPIWithRetry() }
        }
        RunLoop.main.add(timer, forMode: .common)
        retryTimer = timer
        timer.fire()
    }

    private func stopRetry() {
        retryTimer?.invalidate()
        retryTimer = nil
        retryCount = 0
        probeAPIService = nil
    }

    private func testAPIWithRetry() {
        guard case .testingAPI = phase else { return }

        retryCount += 1
        phase = .testingAPI(attempt: retryCount)
        NSLog("🔍 API test %d/%d...", retryCount, maxRetries)

        Task { [weak self] in
            guard let self = self else { return }
            guard case .testingAPI = self.phase else { return }
            guard let probe = self.probeAPIService else { return }

            do {
                _ = try await probe.fetchState()

                guard case .testingAPI = self.phase else { return }
                NSLog("✅ API ready after %d attempts!", self.retryCount)
                await self.connectToMilo()

            } catch {
                guard case .testingAPI = self.phase else { return }
                NSLog("❌ API test %d failed: %@", self.retryCount, error.localizedDescription)

                if self.retryCount >= self.maxRetries {
                    NSLog("🚫 %d attempts failed - resuming mDNS discovery...", self.maxRetries)
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

    private func connectToMilo() async {
        guard case .testingAPI = phase else { return }

        connectionGeneration += 1
        let myGeneration = connectionGeneration

        NSLog("🔌 Connecting to Milo (gen %d)...", myGeneration)

        stopRetry()
        phase = .connecting

        // Résoudre l'IP IPv4 AVANT de connecter
        let best = await Self.resolveBestIPv4(host: host, port: httpPort)

        // Vérifier qu'on est toujours en phase connecting
        guard case .connecting = phase, connectionGeneration == myGeneration else { return }

        if let best {
            resolvedIPv4 = best
            NSLog("✅ Resolved %@ to IPv4: %@", host, best)
            rocVADManager?.updateMiloHost(best)
        }

        let hostToUse = resolvedIPv4 ?? host
        let urlString = "ws://\(hostToUse):\(wsPort)/ws"

        webSocketService.resetSession()
        webSocketService.connect(to: urlString, generation: myGeneration)
    }

    private func handleConnectionSuccess() {
        NSLog("🎉 Milo connected successfully!")

        phase = .connected
        // Transmettre l'IP validée par le test de latence : laisser le service
        // HTTP re-résoudre de son côté pourrait choisir une autre adresse
        // (interface Wi-Fi vs Ethernet du Pi, bail périmé) que celle sondée.
        apiService = MiloAPIService(host: host, port: httpPort, resolvedIPv4: resolvedIPv4)
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

    isolated deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        stop()
    }

    // MARK: - Tests

#if DEBUG
    /// Installe le service HTTP d'une connexion établie en pointant sur un backend local,
    /// sans mDNS ni WebSocket. Réservé aux tests : ils peuvent ainsi appeler les méthodes
    /// de `MiloConnectionManagerDelegate` sur un vrai serveur (la pile URLSession, le
    /// parsing et les retries sont exercés pour de bon), là où la découverte mDNS impose
    /// un `milo.local` sur le réseau.
    func injectAPIServiceForTesting(host: String, port: Int) {
        phase = .connected
        apiService = MiloAPIService(host: host, port: port, resolvedIPv4: host)
    }
#endif
}

// MARK: - WebSocketServiceDelegate
extension MiloConnectionManager: WebSocketServiceDelegate {
    func webSocketDidConnect() {
        handleConnectionSuccess()
    }

    func webSocketDidDisconnect() {
        handleDisconnection()
    }

    func webSocketDidFailToConnect() {
        // Handshake jamais abouti (port 8000 fermé, service WS pas encore prêt).
        // Sans cette voie de sortie, la machine resterait en .connecting pour
        // toujours : mDNS et retry sont déjà arrêtés à ce stade. On ne réagit
        // qu'en phase .connecting — un teardown volontaire (stop, sleep/wake)
        // ne doit pas ressusciter la découverte via un callback tardif.
        guard case .connecting = phase else { return }

        NSLog("💔 WebSocket handshake failed - resuming discovery...")
        stopRetry()
        phase = .discovering
        startDiscovery()
    }

    func didReceiveStateUpdate(_ state: MiloState) {
        delegate?.didReceiveStateUpdate(state)
    }

    func didReceiveVolumeUpdate(_ volume: VolumeStatus) {
        delegate?.didReceiveVolumeUpdate(volume)
    }

    func didReceiveMultiroomTransitionComplete(success: Bool) {
        delegate?.didReceiveMultiroomTransitionComplete(success: success)
    }

    func didReceiveMultiroomStructureChanged() {
        delegate?.didReceiveMultiroomStructureChanged()
    }

    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume) {
        delegate?.didReceiveMultiroomVolumeUpdate(volume)
    }

    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double) {
        delegate?.didReceiveVolumeLimitsUpdate(minDb: minDb, maxDb: maxDb)
    }

    func didReceiveDockAppsUpdate(_ enabledApps: [String]) {
        delegate?.didReceiveDockAppsUpdate(enabledApps)
    }
}

// MARK: - NetServiceBrowserDelegate

/// `NetServiceBrowser` et `NetService` livrent leurs rappels sur la run loop où ils ont été
/// programmés — ici la principale, puisque le browser est créé et les résolutions lancées
/// depuis le main actor. Les protocoles, eux, ne sont pas annotés : leurs méthodes sont donc
/// `nonisolated`, et rentrent explicitement sur le main actor.
extension MiloConnectionManager: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("🔍 Found service: %@ (type: %@, domain: %@)", service.name, service.type, service.domain)

        // `NetService` est explicitement non-Sendable (Apple pousse vers Network.framework) :
        // le confier au main actor est vu comme un transfert. Il n'en est rien — l'objet
        // *arrive* du main thread et n'est jamais touché ailleurs. On le dit ici, sur cette
        // liaison précise, plutôt que de déclarer tout le type Sendable.
        nonisolated(unsafe) let service = service

        MainActor.assumeIsolated {
            guard case .discovering = phase else { return }

            service.delegate = self
            resolvingServices.insert(service)
            service.resolve(withTimeout: 5.0)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        NSLog("📤 Service removed: %@", service.name)

        let serviceName = service.name.lowercased()
        let hostName = service.hostName?.lowercased() ?? ""

        guard serviceName.contains("milo") || hostName.contains("milo") else { return }

        MainActor.assumeIsolated {
            switch phase {
            case .testingAPI:
                NSLog("📡 Milo service removed during retry - resuming discovery...")
                stopRetry()
                phase = .discovering
                startDiscovery()
            case .connecting, .connected:
                handleDisconnection()
            default:
                break
            }
        }
    }

    nonisolated func netServiceBrowserWillSearch(_ browser: NetServiceBrowser) {
        NSLog("📡 mDNS browser will start searching...")
    }

    nonisolated func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {
        NSLog("🛑 mDNS browser stopped searching")
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String : NSNumber]) {
        NSLog("❌ mDNS browser search failed: %@", String(describing: errorDict))
    }
}

// MARK: - NetServiceDelegate
extension MiloConnectionManager: NetServiceDelegate {
    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        let hostName = sender.hostName ?? ""
        NSLog("✅ Service resolved: %@ -> hostname: %@", sender.name, hostName)

        // Voir netServiceBrowser(_:didFind:moreComing:).
        nonisolated(unsafe) let sender = sender

        MainActor.assumeIsolated {
            resolvingServices.remove(sender)

            guard case .discovering = phase else {
                NSLog("⏭️  Skipping - not in discovering phase")
                return
            }

            let cleanedHostname = hostName.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if cleanedHostname == "milo.local" {
                NSLog("🎯 Confirmed Milo service (hostname: %@) - starting rapid API tests...", hostName)
                startAPIRetry()
            } else {
                NSLog("⏭️  Skipping service %@ (hostname: %@) - not milo.local", sender.name, hostName)
            }
        }
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String : NSNumber]) {
        NSLog("⚠️ Failed to resolve service %@: %@", sender.name, String(describing: errorDict))

        // Voir netServiceBrowser(_:didFind:moreComing:).
        nonisolated(unsafe) let sender = sender

        MainActor.assumeIsolated {
            _ = resolvingServices.remove(sender)
        }
    }
}
