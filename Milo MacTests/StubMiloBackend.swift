import Foundation
import Network

/// Backend Milō minimal, servi en local sur un port éphémère, dont on peut faire échouer
/// `/api/settings/bulk` à volonté.
///
/// C'est un vrai serveur HTTP, pas un mock d'URLSession : les tests exercent ainsi la
/// pile réseau réelle de l'app (URLSession, codes d'erreur, parsing, retries) plutôt
/// qu'une réimplémentation de celle-ci.
final class StubMiloBackend {

    /// Limites servies par le stub — volontairement différentes des valeurs de repli
    /// (-80/-21) pour qu'un test puisse distinguer « limites chargées » de « repli ».
    static let limitMinDb = -55.0
    static let limitMaxDb = -15.0
    static let enabledApps = ["radio", "spotify"]

    /// Nombre d'appels `/api/settings/bulk` encore à faire échouer (503).
    /// `.max` = échoue toujours ; 0 = répond normalement.
    var bulkFailuresRemaining: Int {
        get { lock.withLock { _bulkFailuresRemaining } }
        set { lock.withLock { _bulkFailuresRemaining = newValue } }
    }

    /// Nombre total d'appels reçus sur `/api/settings/bulk`, échecs compris.
    var bulkHits: Int { lock.withLock { _bulkHits } }

    /// Port éphémère attribué par le noyau au démarrage.
    private(set) var port: Int = 0

    private let listener: NWListener
    private let queue = DispatchQueue(label: "stub.milo.backend")
    private let lock = NSLock()
    private var _bulkFailuresRemaining = 0
    private var _bulkHits = 0

    // MARK: - Cycle de vie

    /// Démarre le stub et attend qu'il écoute réellement.
    static func start() throws -> StubMiloBackend {
        let backend = try StubMiloBackend()
        try backend.startListening()
        return backend
    }

    private init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Port .any : le noyau en attribue un libre, donc aucun conflit entre tests.
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
        port = Int(assigned)
    }

    func stop() {
        listener.cancel()
    }

    // MARK: - Requêtes

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8) else {
                connection.cancel()
                return
            }

            // « GET /api/settings/bulk HTTP/1.1 » → « /api/settings/bulk »
            let path = request.split(separator: "\r\n").first?
                .split(separator: " ").dropFirst().first.map(String.init) ?? ""

            connection.send(content: self.response(for: path),
                            completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(for path: String) -> Data {
        switch path {
        case "/api/settings/bulk":
            let shouldFail: Bool = lock.withLock {
                _bulkHits += 1
                guard _bulkFailuresRemaining > 0 else { return false }
                if _bulkFailuresRemaining != .max { _bulkFailuresRemaining -= 1 }
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
            return Self.http(json: """
                {"active_source":"spotify","source_state":"active","transitioning":false,\
                "multiroom_enabled":false,"equalizer_effects_enabled":true,"metadata":{}}
                """)

        case "/api/volume/state":
            return Self.http(json: #"{"data":{"global_volume_db":-30,"mode":"direct"}}"#)

        default:
            return Self.http(status: "404 Not Found", json: "{}")
        }
    }

    /// Réponse HTTP/1.1 fermée après chaque requête : URLSession n'a alors aucune
    /// connexion à recycler, ce qui garde le stub trivial (une requête = une connexion).
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
