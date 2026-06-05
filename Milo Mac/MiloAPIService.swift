import Foundation

struct MiloState {
    let activeSource: String
    let sourceState: String       // "starting", "waiting", "active", "error"
    let transitioning: Bool       // true pendant un changement de source
    let multiroomEnabled: Bool
    let equalizerEnabled: Bool
    let metadata: [String: Any]
}

struct VolumeStatus {
    let volumeDb: Double          // Volume en dB (-80 à 0)
    let multiroomEnabled: Bool
    let dspAvailable: Bool
    let limitMinDb: Double        // Limite min configurée (défaut -80)
    let limitMaxDb: Double        // Limite max configurée (défaut -21)

    /// Volume arrondi pour affichage
    var displayText: String {
        return "\(Int(round(volumeDb))) dB"
    }
}

/// Réglages statiques du device, servis en un seul appel par `/api/settings/bulk`
/// (remplace les anciennes routes par catégorie volume-limits / dock-apps).
struct BulkSettings {
    let limitMinDb: Double
    let limitMaxDb: Double
    let enabledApps: [String]
}

class MiloAPIService {
    private let baseURL: String
    private var session: URLSession
    // Dedicated session for endpoints where the backend holds the HTTP
    // connection open for the full duration of a slow operation (e.g. multiroom
    // toggle blocks on snapserver start + source restart + volume push, up to
    // ~20s). The fast session's 3s/5s timeouts would fire mid-transition.
    private var longSession: URLSession
    private let host: String
    private let port: Int
    private var resolvedIPv4: String?

    // Limites de volume : config statique du device servie par /api/settings/bulk.
    // Mises en cache une fois à la connexion (via fetchBulkSettings) pour que le
    // HUD volume ne tire pas tout le payload /bulk à chaque getVolumeStatus() —
    // c'est ce que fait le frontend Milō via son settingsStore. Les défauts
    // correspondent aux valeurs de repli de VolumeHUD.
    private var cachedLimitMinDb: Double = -80.0
    private var cachedLimitMaxDb: Double = -21.0

    init(host: String, port: Int = 80) {
        self.host = host
        self.port = port
        self.baseURL = "http://\(host):\(port)"

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil

        self.session = URLSession(configuration: config)
        self.longSession = Self.makeLongSession()

        // Résoudre l'IP IPv4 en arrière-plan pour éviter les priority inversions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.resolveIPv4Address()
        }
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

    /// Recréer la session pour éviter les connexions TCP stales
    func resetSession() {
        session.invalidateAndCancel()
        longSession.invalidateAndCancel()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil

        session = URLSession(configuration: config)
        longSession = Self.makeLongSession()

        // Re-résoudre l'IP en arrière-plan
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.resolveIPv4Address()
        }
    }

    /// Résout le hostname en IPv4 et le cache
    private func resolveIPv4Address() {
        let host = CFHostCreateWithName(nil, self.host as CFString).takeRetainedValue()
        CFHostStartInfoResolution(host, .addresses, nil)

        var success: DarwinBoolean = false
        if let addresses = CFHostGetAddressing(host, &success)?.takeUnretainedValue() as NSArray? {
            for case let address as NSData in addresses {
                var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(address.bytes.assumingMemoryBound(to: sockaddr.self),
                             socklen_t(address.length),
                             &hostname,
                             socklen_t(hostname.count),
                             nil, 0, NI_NUMERICHOST) == 0 {
                    let ipAddress = String(cString: hostname)
                    // Ne garder que l'IPv4 (pas d'IPv6 avec ":")
                    if !ipAddress.contains(":") {
                        resolvedIPv4 = ipAddress
                        NSLog("✅ Resolved \(self.host) to IPv4: \(ipAddress)")
                        return
                    }
                }
            }
        }
    }

    /// Construit l'URL en utilisant l'IP IPv4 si disponible
    private func buildURL(path: String) -> URL? {
        let hostToUse = resolvedIPv4 ?? host
        return URL(string: "http://\(hostToUse):\(port)\(path)")
    }
    
    func fetchState() async throws -> MiloState {
        guard let url = buildURL(path: "/api/audio/state") else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }
        
        return MiloState(
            activeSource: json["active_source"] as? String ?? "none",
            sourceState: json["source_state"] as? String ?? "active",
            transitioning: json["transitioning"] as? Bool ?? false,
            multiroomEnabled: json["multiroom_enabled"] as? Bool ?? false,
            equalizerEnabled: json["equalizer_effects_enabled"] as? Bool ?? true,
            metadata: json["metadata"] as? [String: Any] ?? [:]
        )
    }
    
    func changeSource(_ source: String) async throws {
        guard let url = buildURL(path: "/api/audio/source/\(source)") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }
    
    func setMultiroom(_ enabled: Bool) async throws {
        guard let url = buildURL(path: "/api/routing/multiroom") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["enabled": enabled]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        // Backend blocks until the full routing transition completes (up to ~20s).
        let (_, response) = try await longSession.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }
    
    /// Lit la valeur de volume + le mode en direct. Les limites proviennent du
    /// cache amorcé par fetchBulkSettings() à la connexion (plus de fetch REST
    /// des limites ici — voir la migration vers /bulk). Le step n'est plus porté :
    /// le pas du raccourci clavier est un réglage local (GlobalHotkeyManager.volumeDeltaDb).
    func getVolumeStatus() async throws -> VolumeStatus {
        guard let stateUrl = buildURL(path: "/api/volume/state") else {
            throw APIError.invalidURL
        }

        let (stateData, stateResponse) = try await session.data(from: stateUrl)

        guard let stateHttp = stateResponse as? HTTPURLResponse, stateHttp.statusCode == 200 else {
            throw APIError.httpError
        }

        guard let stateJson = try JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let dataDict = stateJson["data"] as? [String: Any] else {
            throw APIError.invalidResponse
        }

        let volumeDb = (dataDict["global_volume_db"] as? Double) ?? Double(dataDict["global_volume_db"] as? Int ?? 0)
        let mode = dataDict["mode"] as? String ?? "direct"

        return VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: mode == "multiroom",
            dspAvailable: true,
            limitMinDb: cachedLimitMinDb,
            limitMaxDb: cachedLimitMaxDb
        )
    }

    func adjustVolumeDb(_ deltaDb: Double) async throws {
        guard let url = buildURL(path: "/api/volume/adjust") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["delta_db": deltaDb, "show_bar": true]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }

    // MARK: - DSP API

    func setEqualizer(_ enabled: Bool) async throws {
        guard let url = buildURL(path: "/api/equalizer/target/local/enabled") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["enabled": enabled]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }

    // MARK: - Settings API

    /// Récupère les réglages statiques du device (limites volume + dock apps) en un
    /// seul appel. Remplace les anciennes routes par catégorie /api/settings/volume-limits
    /// et /api/settings/dock-apps — mêmes sous-clés, enveloppe différente :
    ///   volume-limits {"limits": {...}} → bulk {"volume_limits": {...}}
    ///   dock-apps     {"config": {...}} → bulk {"dock_apps": {...}}
    /// Effet de bord : amorce le cache des limites lu par getVolumeStatus().
    func fetchBulkSettings() async throws -> BulkSettings {
        guard let url = buildURL(path: "/api/settings/bulk") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw APIError.invalidResponse
        }

        // volume_limits.{min_db,max_db} : sous-clés identiques à l'ancienne route ;
        // on retombe sur le cache courant si la clé est absente (jamais 0/0).
        let limits = json["volume_limits"] as? [String: Any]
        let limitMin = (limits?["min_db"] as? Double) ?? (limits?["min_db"] as? Int).map(Double.init) ?? cachedLimitMinDb
        let limitMax = (limits?["max_db"] as? Double) ?? (limits?["max_db"] as? Int).map(Double.init) ?? cachedLimitMaxDb

        // dock_apps.enabled_apps : sous-clé identique à l'ancienne route.
        let dockApps = json["dock_apps"] as? [String: Any]
        let enabledApps = dockApps?["enabled_apps"] as? [String] ?? []

        cachedLimitMinDb = limitMin
        cachedLimitMaxDb = limitMax

        return BulkSettings(limitMinDb: limitMin, limitMaxDb: limitMax, enabledApps: enabledApps)
    }

    /// Met à jour le cache de limites suite à l'événement WS `settings/volume_limits_changed`
    /// (les limites ont changé côté device). getVolumeStatus() lira ces nouvelles valeurs
    /// — évite de re-tirer /bulk à chaque séquence du raccourci clavier.
    func updateCachedLimits(minDb: Double, maxDb: Double) {
        cachedLimitMinDb = minDb
        cachedLimitMaxDb = maxDb
    }

    // MARK: - Radio API

    func getRadioFavorites() async throws -> [[String: Any]] {
        guard let url = buildURL(path: "/api/radio/stations?favorites_only=true") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let stations = json["stations"] as? [[String: Any]] else {
            throw APIError.invalidResponse
        }

        return stations
    }

    func playRadioStation(_ stationId: String) async throws {
        guard let url = buildURL(path: "/api/radio/play") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["station_id": stationId]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }

    func stopRadioPlayback() async throws {
        guard let url = buildURL(path: "/api/radio/stop") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }
}

enum APIError: Error {
    case invalidURL
    case httpError
    case invalidResponse
}
