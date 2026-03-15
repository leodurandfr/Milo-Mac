import Foundation

struct MiloState {
    let activeSource: String
    let pluginState: String       // "starting", "ready", "connected", "error" - INDICATEUR utilisé pour les spinners
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
    let stepMobileDb: Double      // Step pour les ajustements (défaut 3)

    /// Volume arrondi pour affichage
    var displayText: String {
        return "\(Int(round(volumeDb))) dB"
    }
}

class MiloAPIService {
    private let baseURL: String
    private var session: URLSession
    private let host: String
    private let port: Int
    private var resolvedIPv4: String?

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

        // Résoudre l'IP IPv4 en arrière-plan pour éviter les priority inversions
        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.resolveIPv4Address()
        }
    }

    /// Recréer la session pour éviter les connexions TCP stales
    func resetSession() {
        session.invalidateAndCancel()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 3.0
        config.timeoutIntervalForResource = 5.0
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.urlCache = nil

        session = URLSession(configuration: config)

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
            pluginState: json["plugin_state"] as? String ?? "ready",  // "starting" déclenche le spinner
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
        guard let url = buildURL(path: "/api/routing/multiroom/\(enabled)") else {
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
    
    func getVolumeStatus() async throws -> VolumeStatus {
        guard let stateUrl = buildURL(path: "/api/volume/state"),
              let limitsUrl = buildURL(path: "/api/settings/volume-limits"),
              let stepsUrl = buildURL(path: "/api/settings/volume-steps") else {
            throw APIError.invalidURL
        }

        // Fetch volume state, limits, and steps in parallel
        async let stateResult = session.data(from: stateUrl)
        async let limitsResult = session.data(from: limitsUrl)
        async let stepsResult = session.data(from: stepsUrl)

        let (stateData, stateResponse) = try await stateResult
        let (limitsData, limitsResponse) = try await limitsResult
        let (stepsData, stepsResponse) = try await stepsResult

        guard let stateHttp = stateResponse as? HTTPURLResponse, stateHttp.statusCode == 200,
              let limitsHttp = limitsResponse as? HTTPURLResponse, limitsHttp.statusCode == 200,
              let stepsHttp = stepsResponse as? HTTPURLResponse, stepsHttp.statusCode == 200 else {
            throw APIError.httpError
        }

        guard let stateJson = try JSONSerialization.jsonObject(with: stateData) as? [String: Any],
              let dataDict = stateJson["data"] as? [String: Any],
              let limitsJson = try JSONSerialization.jsonObject(with: limitsData) as? [String: Any],
              let limits = limitsJson["limits"] as? [String: Any],
              let stepsJson = try JSONSerialization.jsonObject(with: stepsData) as? [String: Any],
              let stepsConfig = stepsJson["config"] as? [String: Any] else {
            throw APIError.invalidResponse
        }

        let volumeDb = (dataDict["global_volume_db"] as? Double) ?? Double(dataDict["global_volume_db"] as? Int ?? 0)
        let mode = dataDict["mode"] as? String ?? "direct"
        let limitMin = (limits["min_db"] as? Double) ?? Double(limits["min_db"] as? Int ?? 0)
        let limitMax = (limits["max_db"] as? Double) ?? Double(limits["max_db"] as? Int ?? 0)
        let stepMobile = (stepsConfig["step_mobile_db"] as? Double) ?? Double(stepsConfig["step_mobile_db"] as? Int ?? 0)

        return VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: mode == "multiroom",
            dspAvailable: true,
            limitMinDb: limitMin,
            limitMaxDb: limitMax,
            stepMobileDb: stepMobile
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
        guard let url = buildURL(path: "/api/equalizer/enabled") else {
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

    func fetchDockApps() async throws -> [String] {
        guard let url = buildURL(path: "/api/settings/dock-apps") else {
            throw APIError.invalidURL
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }

        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let config = json["config"] as? [String: Any],
              let enabledApps = config["enabled_apps"] as? [String] else {
            throw APIError.invalidResponse
        }

        return enabledApps
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
