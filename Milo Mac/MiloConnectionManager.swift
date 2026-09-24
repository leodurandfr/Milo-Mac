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

/// Every callback is delivered on the main thread — that was already the case, it is now
/// a signature rather than a convention.
///
/// `Sendable`: the delegate is sometimes taken out and then released on the main queue (see
/// `stop()`, called from `deinit`). Its conformers are `@MainActor` classes, hence Sendable
/// in their own right.
@MainActor
protocol MiloConnectionManagerDelegate: AnyObject, Sendable {
    func miloDidConnect()
    func miloDidDisconnect()
    func didReceiveStateUpdate(_ state: MiloAudioState)
    func didReceiveVolumeUpdate(_ volume: VolumeStatus)
    func didReceiveMultiroomTransitionComplete(success: Bool)
    func didReceiveMultiroomStructureChanged()
    func didReceiveMultiroomVolumeUpdate(_ volume: MultiroomVolume)
    func didReceiveVolumeLimitsUpdate(minDb: Double, maxDb: Double)
    func didReceiveDockAppsUpdate(_ enabledApps: [String])
}

/// Discovery of and connection to Milō: mDNS → API readiness checks → WebSocket.
///
/// Main-thread-only, now checked. The phase machine, the discovery state and the timers
/// belong to the main actor; only the genuinely blocking work (CFHost resolution, TCP
/// latency probes) goes off the main thread — and it does so through `await`, so it comes
/// back on its own.
@MainActor
final class MiloConnectionManager: NSObject {
    weak var delegate: MiloConnectionManagerDelegate?

    // A reference to RocVADManager, to update the endpoint with the resolved IP
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
    /// The active connection's HTTP service. Created on connect, nil otherwise.
    private(set) var apiService: MiloAPIService?
    /// A single instance reused for the 20 readiness checks — creating one
    /// per attempt leaked two URLSessions every 2 seconds.
    private var probeAPIService: MiloAPIService?

    // mDNS/Bonjour Discovery
    private var serviceBrowser: NetServiceBrowser?
    private var resolvingServices: Set<NetService> = []

    // Targeted retry (when mDNS finds the Pi)
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

    /// Delivered by NSWorkspace on the main thread.
    @objc private nonisolated func systemDidWake() {
        NSLog("☀️ System woke up - forcing reconnection...")

        Task { @MainActor [weak self] in
            // Let the network stack settle after waking.
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

    /// Resolves the hostname to IPv4 and, when there are several candidates, keeps the
    /// fastest one.
    ///
    /// `nonisolated`: `IPv4Resolver.resolveAll` (CFHost) blocks, and the TCP probes take up
    /// to 500 ms each — none of that belongs on the main actor. The caller only has to
    /// `await`, and gets the main actor back on its own.
    ///
    /// The resolution is explicitly pushed onto a `.utility` queue: this method is called
    /// from `connectToMilo()` on the main actor, so structured concurrency's cooperative
    /// pool inherits a `.userInitiated` QoS. `CFHostStartInfoResolution` blocks the calling
    /// thread waiting for an answer resolved internally at `.default` QoS — without this
    /// hop, a `.userInitiated` thread waits on a `.default` thread, the priority inversion
    /// Instruments flags ("Hang Risk"). `.utility` (< `.default`) turns the wait into a
    /// plain downward priority donation, not an inversion.
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

        // The probes run in parallel and bound themselves to 500 ms: the global
        // `DispatchGroup.wait(timeout:)` from before is no longer needed.
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

    /// Measures the latency to an IP through a quick TCP connection.
    ///
    /// The continuation must be resumed **exactly once**, while the state handler and the
    /// 500 ms timeout run in parallel: hence the flag under a lock. It used to be a
    /// `var hasCompleted` + NSLock, which the compiler could not follow; a `Mutex` says the
    /// same thing, and proves it.
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

            // 500 ms timeout
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
            // Capture the delegate rather than `self`: stop() is also called from
            // deinit, and forming a weak reference to an object being deallocated
            // crashes the objc runtime.
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

    // MARK: - Targeted retry (when mDNS finds Milo)

    private func startAPIRetry() {
        guard case .discovering = phase else { return }

        NSLog("🔄 Milo detected - starting %d rapid API tests...", maxRetries)

        stopDiscovery()

        retryCount = 0
        phase = .testingAPI(attempt: 0)
        probeAPIService = MiloAPIService(host: host, port: httpPort)

        // .common mode: keep the checks running even if the user holds the menu
        // open (the default mode suspends timers during tracking).
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
                try await probe.probeState()

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

        // Resolve the IPv4 address BEFORE connecting
        let best = await Self.resolveBestIPv4(host: host, port: httpPort)

        // Check we are still in the connecting phase
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
        // Pass on the IP validated by the latency check: letting the HTTP service
        // re-resolve on its own side could pick a different address (the Pi's Wi-Fi
        // vs Ethernet interface, a stale lease) than the one probed.
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
    /// Installs an established connection's HTTP service, pointing at a local backend, with
    /// no mDNS and no WebSocket. Reserved for the tests: they can thereby call the
    /// `MiloConnectionManagerDelegate` methods against a real server (the URLSession stack,
    /// the parsing and the retries are exercised for real), where mDNS discovery would
    /// require a `milo.local` on the network.
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
        // The handshake never completed (port 8000 closed, WS service not ready yet).
        // Without this way out, the machine would stay in .connecting forever:
        // mDNS and retry are already stopped at this point. We only react while in
        // the .connecting phase — a deliberate teardown (stop, sleep/wake) must not
        // resurrect discovery through a late callback.
        guard case .connecting = phase else { return }

        NSLog("💔 WebSocket handshake failed - resuming discovery...")
        stopRetry()
        phase = .discovering
        startDiscovery()
    }

    func didReceiveStateUpdate(_ state: MiloAudioState) {
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

/// `NetServiceBrowser` and `NetService` deliver their callbacks on the run loop they were
/// scheduled on — here the main one, since the browser is created and the resolutions
/// started from the main actor. The protocols themselves are not annotated: their methods
/// are therefore `nonisolated`, and enter the main actor explicitly.
extension MiloConnectionManager: NetServiceBrowserDelegate {
    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        NSLog("🔍 Found service: %@ (type: %@, domain: %@)", service.name, service.type, service.domain)

        // `NetService` is explicitly non-Sendable (Apple pushes towards Network.framework):
        // handing it to the main actor is seen as a transfer. It is nothing of the sort —
        // the object *comes from* the main thread and is never touched anywhere else. We say
        // so here, on this precise binding, rather than declaring the whole type Sendable.
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

        // See netServiceBrowser(_:didFind:moreComing:).
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

        // See netServiceBrowser(_:didFind:moreComing:).
        nonisolated(unsafe) let sender = sender

        MainActor.assumeIsolated {
            _ = resolvingServices.remove(sender)
        }
    }
}
