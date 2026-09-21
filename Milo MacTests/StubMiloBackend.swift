import Foundation
import Network
import Synchronization

/// A minimal Milō backend, served locally on an ephemeral port, whose
/// `/api/settings/bulk` can be made to fail at will.
///
/// This is a real HTTP server, not a mocked URLSession: the tests thereby exercise the
/// app's real networking stack (URLSession, error codes, parsing, retries) rather than a
/// reimplementation of it.
///
/// `Sendable` checked: it is driven from the tests (main actor) and serves its requests
/// on its own queue — so all of its mutable state sits under a `Mutex`, like that of
/// `MiloAPIService`.
final class StubMiloBackend: Sendable {

    /// Limits served by the stub — deliberately different from the fallback values
    /// (-80/-21) so a test can tell "limits loaded" from "fallback".
    static let limitMinDb = -55.0
    static let limitMaxDb = -15.0
    static let enabledApps = ["radio", "spotify"]

    /// The multiroom client served by `/api/multiroom/state` and `/api/volume/state`: one
    /// is enough to tell "volume loaded" from "volume emptied".
    static let clientMac = "aa:bb:cc:dd:ee:ff"
    static let clientVolumeDb = -33.0

    private struct State {
        /// Number of `/api/settings/bulk` calls still to be failed (503).
        /// `.max` = always fails; 0 = answers normally.
        var bulkFailuresRemaining = 0
        /// Total number of calls received on `/api/settings/bulk`, failures included.
        var bulkHits = 0
        /// Ephemeral port assigned by the kernel at startup.
        var port = 0
        /// Serves `/api/audio/state` with multiroom ACTIVE — the store then loads, on its
        /// own, the multiroom structure and the per-client volumes.
        var multiroomEnabled = false
        /// Makes `/api/volume/state` answer 200 + {"status":"error"}: the envelope Milō
        /// serves on exception (backend/api/volume.py), not an HTTP failure status.
        var volumeStateFails = false
        /// Number of calls served on `/api/volume/state`, errors included.
        var volumeStateHits = 0
        /// Makes `PUT /api/equalizer/target/local/enabled` answer 200 + {"status":"error"}:
        /// what the backend returns when the target refuses (backend/api/equalizer.py).
        var equalizerRefuses = false
    }

    private let state = Mutex(State())

    var bulkFailuresRemaining: Int {
        get { state.withLock { $0.bulkFailuresRemaining } }
        set { state.withLock { $0.bulkFailuresRemaining = newValue } }
    }

    var bulkHits: Int { state.withLock { $0.bulkHits } }

    var port: Int { state.withLock { $0.port } }

    var multiroomEnabled: Bool {
        get { state.withLock { $0.multiroomEnabled } }
        set { state.withLock { $0.multiroomEnabled = newValue } }
    }

    var volumeStateFails: Bool {
        get { state.withLock { $0.volumeStateFails } }
        set { state.withLock { $0.volumeStateFails = newValue } }
    }

    var volumeStateHits: Int { state.withLock { $0.volumeStateHits } }

    var equalizerRefuses: Bool {
        get { state.withLock { $0.equalizerRefuses } }
        set { state.withLock { $0.equalizerRefuses = newValue } }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub.milo.backend")

    // MARK: - Lifecycle

    /// Starts the stub and waits until it is really listening.
    static func start() throws -> StubMiloBackend {
        let backend = try StubMiloBackend()
        try backend.startListening()
        return backend
    }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port .any: the kernel assigns a free one, so no conflict between tests.
        listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
    }

    private func startListening() throws {
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.start(queue: queue)

        guard ready.wait(timeout: .now() + 5) == .success,
              let assigned = listener.port?.rawValue else {
            throw StubError.didNotStart
        }
        state.withLock { $0.port = Int(assigned) }
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Requests

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // "GET /api/settings/bulk HTTP/1.1" → "/api/settings/bulk"
            let path = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? ""

            connection.send(content: self.response(for: path),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(for path: String) -> Data {
        switch path {
        case "/api/settings/bulk":
            let shouldFail: Bool = state.withLock { state in
                state.bulkHits += 1
                guard state.bulkFailuresRemaining > 0 else { return false }
                if state.bulkFailuresRemaining != .max { state.bulkFailuresRemaining -= 1 }
                return true
            }
            if shouldFail {
                return Self.http(status: "503 Service Unavailable", json: "{}")
            }

            let apps = Self.enabledApps.map { "\"\($0)\"" }.joined(separator: ",")
            return Self.http(json: """
                {"volume_limits":{"min_db":\(Self.limitMinDb),"max_db":\(Self.limitMaxDb)},\
                "dock_apps":{"enabled_apps":[\(apps)]}}
                """)

        case "/api/audio/state":
            let multiroom = state.withLock { $0.multiroomEnabled }
            return Self.http(json: """
                {"active_source":"spotify","source_state":"active","transitioning":false,\
                "multiroom_enabled":\(multiroom),"equalizer_effects_enabled":true,"metadata":{}}
                """)

        case "/api/volume/state":
            let (fails, multiroomMode) = state.withLock { state -> (Bool, Bool) in
                state.volumeStateHits += 1
                return (state.volumeStateFails, state.multiroomEnabled)
            }
            // 200 with status:error — it really is the envelope, not the HTTP status, that
            // carries this route's failure.
            if fails {
                return Self.http(json: #"{"status":"error","message":"volume service unavailable"}"#)
            }
            return Self.http(json: """
                {"status":"success","data":{"global_volume_db":-30,\
                "mode":"\(multiroomMode ? "multiroom" : "direct")",\
                "clients":{"\(Self.clientMac)":{"volume_db":\(Self.clientVolumeDb),\
                "mute":false,"available":true}},"zones":{}}}
                """)

        case "/api/multiroom/state":
            return Self.http(json: """
                {"clients":{"\(Self.clientMac)":{"mac_id":"\(Self.clientMac)","name":"Salon",\
                "online":true,"volume_db":\(Self.clientVolumeDb),"mute":false,\
                "volume_control":true,"ip":"192.168.1.42"}},"zones":{}}
                """)

        case "/api/equalizer/target/local/enabled":
            let refuses = state.withLock { $0.equalizerRefuses }
            return Self.http(json: refuses
                ? #"{"status":"error","target":"local","enabled":false}"#
                : #"{"status":"success","target":"local","enabled":false}"#)

        default:
            return Self.http(status: "404 Not Found", json: "{}")
        }
    }

    /// An HTTP/1.1 response closed after every request: URLSession then has no connection
    /// to recycle, which keeps the stub trivial (one request = one connection).
    private static func http(status: String = "200 OK", json: String) -> Data {
        let body = Data(json.utf8)
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        return Data(head.utf8) + body
    }

    enum StubError: Error {
        case didNotStart
    }
}
