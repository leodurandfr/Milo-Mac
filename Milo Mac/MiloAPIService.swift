import Foundation
import Synchronization

/// Convertit le `[String: Any]` de `JSONSerialization` en dictionnaire réellement
/// **Sendable**.
///
/// `MiloState` franchit une frontière d'isolation — il est décodé hors du main actor
/// (queue déléguée d'URLSession pour le WebSocket, pool Swift-concurrency pour le HTTP)
/// puis remis au main actor, qui le possède. Sa `metadata` doit donc être Sendable pour
/// de vrai.
///
/// Et non par un `as? [String: any Sendable]` : `Sendable` est un protocole *marqueur*,
/// sans représentation à l'exécution — ce cast « réussit toujours » sans rien vérifier.
/// Ce serait un `@unchecked` déguisé. On reconstruit donc explicitement, à partir des
/// seuls types que `JSONSerialization` produit.
///
/// Les `NSNumber` sont conservés tels quels (ils *sont* Sendable) : les lectures
/// `as? Int` / `as? Bool` du reste de l'app gardent exactement le même comportement de
/// pont Objective-C qu'avec un `[String: Any]`.
enum JSONSendable {
    static func dictionary(_ raw: [String: Any]) -> [String: any Sendable] {
        raw.compactMapValues(value)
    }

    private static func value(_ any: Any) -> (any Sendable)? {
        switch any {
        case let number as NSNumber:      return number   // Int, Double et Bool
        case let string as String:        return string
        case let array as [Any]:          return array.compactMap(value)
        case let object as [String: Any]: return dictionary(object)
        default:                          return nil      // NSNull et inconnus
        }
    }
}

struct MiloState: Sendable {
    let activeSource: String
    let sourceState: String       // "starting", "waiting", "active", "error"
    let transitioning: Bool       // true pendant un changement de source
    let multiroomEnabled: Bool
    let equalizerEnabled: Bool
    let metadata: [String: any Sendable]

    /// Décodage unique du payload backend — partagé entre le fetch HTTP
    /// (/api/audio/state) et le `full_state` des événements WebSocket,
    /// pour que les deux transports ne puissent pas diverger.
    init(json: [String: Any]) {
        activeSource = json["active_source"] as? String ?? "none"
        sourceState = json["source_state"] as? String ?? "active"
        transitioning = json["transitioning"] as? Bool ?? false
        multiroomEnabled = json["multiroom_enabled"] as? Bool ?? false
        equalizerEnabled = json["equalizer_effects_enabled"] as? Bool ?? true
        metadata = JSONSendable.dictionary(json["metadata"] as? [String: Any] ?? [:])
    }
}

/// Bornes de volume de repli, utilisées avant que le premier fetch
/// /api/settings/bulk n'amorce les vraies limites du device.
/// Définition unique pour le slider du menu, le HUD et le raccourci clavier.
enum VolumeDefaults {
    static let limitMinDb = -80.0
    static let limitMaxDb = -21.0
}

struct VolumeStatus {
    let volumeDb: Double          // Volume en dB (-80 à 0)
    let multiroomEnabled: Bool
    let dspAvailable: Bool
    let limitMinDb: Double        // Limite min configurée
    let limitMaxDb: Double        // Limite max configurée

    /// Copie avec de nouvelles bornes — sert à préserver les limites en cache
    /// quand un événement WebSocket n'en porte pas (voir CLAUDE.md).
    func withLimits(minDb: Double, maxDb: Double) -> VolumeStatus {
        VolumeStatus(volumeDb: volumeDb,
                     multiroomEnabled: multiroomEnabled,
                     dspAvailable: dspAvailable,
                     limitMinDb: minDb,
                     limitMaxDb: maxDb)
    }
}

/// Réglages statiques du device, servis en un seul appel par `/api/settings/bulk`
/// (remplace les anciennes routes par catégorie volume-limits / dock-apps).
struct BulkSettings {
    let limitMinDb: Double
    let limitMaxDb: Double
    let enabledApps: [String]
}

/// Station radio telle que servie par /api/radio/stations.
struct RadioStation: Decodable {
    let id: String
    let name: String
}

private struct RadioStationsResponse: Decodable {
    let stations: [RadioStation]
}

/// Résolution DNS → IPv4 partagée (bloc CFHost unique pour toute l'app).
/// MiloAPIService prend le premier résultat ; MiloConnectionManager garde la
/// liste complète pour son test de latence. CFHost est soft-déprécié — le jour
/// où on migre vers Network.framework, c'est le seul endroit à changer.
enum IPv4Resolver {
    static func resolveAll(host: String) -> [String] {
        let cfHost = CFHostCreateWithName(nil, host as CFString).takeRetainedValue()
        CFHostStartInfoResolution(cfHost, .addresses, nil)

        var results: [String] = []
        var success: DarwinBoolean = false
        if let addresses = CFHostGetAddressing(cfHost, &success)?.takeUnretainedValue() as NSArray? {
            for case let address as NSData in addresses {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address.bytes.assumingMemoryBound(to: sockaddr.self),
                               socklen_t(address.length),
                               &hostname,
                               socklen_t(hostname.count),
                               nil, 0, NI_NUMERICHOST) == 0 {
                    // Tronquer au NUL terminal puis décoder : `String(cString:)` est déprécié.
                    let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    let ipAddress = String(decoding: bytes, as: UTF8.self)
                    // Ne garder que les IPv4 (pas d'IPv6 avec ":")
                    if !ipAddress.contains(":") {
                        results.append(ipAddress)
                    }
                }
            }
        }
        return results
    }
}

/// Client HTTP du backend Milō.
///
/// Contrairement au reste de l'app, ce service n'est **pas** main-thread-only : il est
/// appelé depuis le pool Swift-concurrency (toutes ses méthodes `async`) et depuis une
/// queue utilitaire de résolution DNS. Son traitement correct est donc `Sendable`, pas
/// `@MainActor`.
///
/// Et un Sendable **vérifié** : tout l'état mutable est enfermé dans un `Mutex`, et les
/// autres propriétés sont des `let`. Là où un `NSLock` + `@unchecked Sendable` demandait
/// au compilateur de nous croire sur parole, ici il vérifie.
final class MiloAPIService: Sendable {
    private let host: String
    private let port: Int

    /// L'état mutable, accédé depuis plusieurs threads — donc rassemblé sous un seul
    /// verrou plutôt qu'éparpillé en propriétés `var`.
    private struct State {
        var session: URLSession
        // Session dédiée aux endpoints où le backend garde la connexion HTTP ouverte
        // pendant toute une opération lente (ex. toggle multiroom : snapserver start
        // + restart source + push volume, jusqu'à ~20 s). Les timeouts 3 s/5 s de la
        // session rapide tomberaient en pleine transition.
        var longSession: URLSession
        var resolvedIPv4: String?
        // Limites de volume : config statique du device servie par /api/settings/bulk.
        // Mises en cache une fois à la connexion (via fetchBulkSettings) pour que le
        // HUD volume ne tire pas tout le payload /bulk à chaque getVolumeStatus() —
        // c'est ce que fait le frontend Milō via son settingsStore.
        var cachedLimitMinDb: Double = VolumeDefaults.limitMinDb
        var cachedLimitMaxDb: Double = VolumeDefaults.limitMaxDb
    }

    private let state: Mutex<State>

    /// Bornes en cache (amorcées par fetchBulkSettings, rafraîchies par le
    /// WebSocket settings/volume_limits_changed via updateCachedLimits).
    var cachedLimits: (minDb: Double, maxDb: Double) {
        state.withLock { ($0.cachedLimitMinDb, $0.cachedLimitMaxDb) }
    }

    /// - Parameter resolvedIPv4: IP déjà validée par l'appelant (le connection
    ///   manager sélectionne la meilleure IP par test de latence). Quand elle est
    ///   fournie, on ne relance pas de résolution indépendante qui pourrait
    ///   choisir une autre adresse que celle qui vient d'être sondée.
    init(host: String, port: Int = 80, resolvedIPv4: String? = nil) {
        self.host = host
        self.port = port
        self.state = Mutex(State(session: Self.makeFastSession(),
                                 longSession: Self.makeLongSession(),
                                 resolvedIPv4: resolvedIPv4))

        if resolvedIPv4 == nil {
            resolveIPv4InBackground()
        }
    }

    deinit {
        // Une URLSession n'est libérée qu'une fois invalidée — indispensable pour
        // les instances jetables (sonde de readiness du connection manager).
        let sessions = state.withLock { ($0.session, $0.longSession) }
        sessions.0.invalidateAndCancel()
        sessions.1.invalidateAndCancel()
    }

    private static func makeFastSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    private static func makeLongSession() -> URLSession {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30.0
        config.timeoutIntervalForResource = 45.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil
        return URLSession(configuration: config)
    }

    /// Recréer les sessions pour éviter les connexions TCP stales
    func resetSession() {
        let old = state.withLock { state -> (URLSession, URLSession) in
            let previous = (state.session, state.longSession)
            state.session = Self.makeFastSession()
            state.longSession = Self.makeLongSession()
            return previous
        }

        old.0.invalidateAndCancel()
        old.1.invalidateAndCancel()

        // Re-résoudre l'IP : si la session est stale, l'adresse peut l'être aussi.
        resolveIPv4InBackground()
    }

    /// Résout le hostname en IPv4 en arrière-plan et met l'adresse en cache.
    private func resolveIPv4InBackground() {
        let host = self.host
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let ip = IPv4Resolver.resolveAll(host: host).first else { return }
            self?.state.withLock { $0.resolvedIPv4 = ip }
            NSLog("✅ Resolved %@ to IPv4: %@", host, ip)
        }
    }

    /// Construit l'URL en utilisant l'IP IPv4 si disponible
    private func buildURL(path: String) -> URL? {
        let hostToUse = state.withLock { $0.resolvedIPv4 } ?? host
        return URL(string: "http://\(hostToUse):\(port)\(path)")
    }

    // MARK: - Requête générique

    /// Construit, exécute et valide une requête ; renvoie le corps de la réponse.
    @discardableResult
    private func send(_ path: String,
                      method: String = "GET",
                      body: [String: Any]? = nil,
                      long: Bool = false) async throws -> Data {
        guard let url = buildURL(path: path) else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }

        let session = state.withLock { long ? $0.longSession : $0.session }
        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw APIError.invalidResponse
        }
        guard httpResponse.statusCode == 200 else {
            throw APIError.httpError(statusCode: httpResponse.statusCode)
        }

        return data
    }

    private func fetchJSON(_ path: String) async throws -> [String: Any] {
        let data = try await send(path)
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return json
    }

    // MARK: - Audio API

    func fetchState() async throws -> MiloState {
        MiloState(json: try await fetchJSON("/api/audio/state"))
    }

    func changeSource(_ source: String) async throws {
        let data = try await send("/api/audio/source/\(source)", method: "POST")

        // Le backend répond 200 avec {"status": "error"} quand la transition
        // échoue — l'échec est dans le corps, pas dans le statut HTTP.
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? String, status != "success" {
            throw APIError.backendError(status)
        }
    }

    func setMultiroom(_ enabled: Bool) async throws {
        // Le backend bloque jusqu'à la fin complète de la transition (~20 s max).
        try await send("/api/routing/multiroom", method: "PUT",
                       body: ["enabled": enabled], long: true)
    }

    // MARK: - Volume API

    /// Lit la valeur de volume + le mode en direct. Les limites proviennent du
    /// cache amorcé par fetchBulkSettings() à la connexion. Le step n'est plus
    /// porté : le pas du raccourci clavier est un réglage local
    /// (GlobalHotkeyManager.volumeDeltaDb).
    func getVolumeStatus() async throws -> VolumeStatus {
        let json = try await fetchJSON("/api/volume/state")

        // Pas de valeur par défaut ici : un payload sans global_volume_db
        // fabriquerait 0 dB (le maximum) — on préfère échouer proprement.
        guard let dataDict = json["data"] as? [String: Any],
              let volumeDb = (dataDict["global_volume_db"] as? Double)
                ?? (dataDict["global_volume_db"] as? Int).map(Double.init) else {
            throw APIError.invalidResponse
        }

        let mode = dataDict["mode"] as? String ?? "direct"
        let limits = cachedLimits

        return VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: mode == "multiroom",
            dspAvailable: true,
            limitMinDb: limits.minDb,
            limitMaxDb: limits.maxDb
        )
    }

    func adjustVolumeDb(_ deltaDb: Double) async throws {
        try await send("/api/volume/adjust", method: "POST",
                       body: ["delta_db": deltaDb, "show_bar": true])
    }

    // MARK: - DSP API

    func setEqualizer(_ enabled: Bool) async throws {
        try await send("/api/equalizer/target/local/enabled", method: "PUT",
                       body: ["enabled": enabled])
    }

    // MARK: - Settings API

    /// Récupère les réglages statiques du device (limites volume + dock apps) en un
    /// seul appel. Remplace les anciennes routes par catégorie /api/settings/volume-limits
    /// et /api/settings/dock-apps — mêmes sous-clés, enveloppe différente :
    ///   volume-limits {"limits": {...}} → bulk {"volume_limits": {...}}
    ///   dock-apps     {"config": {...}} → bulk {"dock_apps": {...}}
    /// Effet de bord : amorce le cache des limites lu par getVolumeStatus().
    func fetchBulkSettings() async throws -> BulkSettings {
        let json = try await fetchJSON("/api/settings/bulk")

        // volume_limits.{min_db,max_db} : sous-clés identiques à l'ancienne route ;
        // on retombe sur le cache courant si la clé est absente (jamais 0/0).
        let current = cachedLimits
        let limits = json["volume_limits"] as? [String: Any]
        let limitMin = (limits?["min_db"] as? Double) ?? (limits?["min_db"] as? Int).map(Double.init) ?? current.minDb
        let limitMax = (limits?["max_db"] as? Double) ?? (limits?["max_db"] as? Int).map(Double.init) ?? current.maxDb

        // dock_apps.enabled_apps : sous-clé identique à l'ancienne route.
        let dockApps = json["dock_apps"] as? [String: Any]
        let enabledApps = dockApps?["enabled_apps"] as? [String] ?? []

        updateCachedLimits(minDb: limitMin, maxDb: limitMax)

        return BulkSettings(limitMinDb: limitMin, limitMaxDb: limitMax, enabledApps: enabledApps)
    }

    /// Met à jour le cache de limites suite à l'événement WS `settings/volume_limits_changed`
    /// (les limites ont changé côté device). getVolumeStatus() lira ces nouvelles valeurs
    /// — évite de re-tirer /bulk à chaque séquence du raccourci clavier.
    func updateCachedLimits(minDb: Double, maxDb: Double) {
        state.withLock {
            $0.cachedLimitMinDb = minDb
            $0.cachedLimitMaxDb = maxDb
        }
    }

    // MARK: - Radio API

    func getRadioFavorites() async throws -> [RadioStation] {
        let data = try await send("/api/radio/stations?favorites_only=true")
        do {
            return try JSONDecoder().decode(RadioStationsResponse.self, from: data).stations
        } catch {
            throw APIError.invalidResponse
        }
    }

    func playRadioStation(_ stationId: String) async throws {
        try await send("/api/radio/play", method: "POST",
                       body: ["station_id": stationId])
    }

    func stopRadioPlayback() async throws {
        try await send("/api/radio/stop", method: "POST")
    }
}

enum APIError: Error, LocalizedError {
    case invalidURL
    case httpError(statusCode: Int)
    case invalidResponse
    case backendError(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL: return "invalid request URL"
        case .httpError(let statusCode): return "HTTP \(statusCode)"
        case .invalidResponse: return "unexpected response payload"
        case .backendError(let status): return "backend returned status \"\(status)\""
        }
    }
}
