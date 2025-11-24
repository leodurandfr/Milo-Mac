import Foundation

struct MiloState {
    let activeSource: String
    let pluginState: String
    let isTransitioning: Bool     // GARDÉ pour compatibilité backend, mais NON UTILISÉ côté Mac
    let targetSource: String?     // SEUL INDICATEUR utilisé pour les spinners
    let multiroomEnabled: Bool
    let equalizerEnabled: Bool
    let metadata: [String: Any]
}

struct VolumeStatus {
    let volume: Int
    let mode: String
    let multiroomEnabled: Bool
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
        
        // NETTOYÉ : targetSource est maintenant LE seul indicateur de transition
        let targetSource = json["target_source"] as? String
        
        return MiloState(
            activeSource: json["active_source"] as? String ?? "none",
            pluginState: json["plugin_state"] as? String ?? "inactive",
            isTransitioning: json["transitioning"] as? Bool ?? false, // IGNORÉ côté Mac
            targetSource: targetSource, // SEUL INDICATEUR utilisé
            multiroomEnabled: json["multiroom_enabled"] as? Bool ?? false,
            equalizerEnabled: json["equalizer_enabled"] as? Bool ?? false,
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
    
    func setEqualizer(_ enabled: Bool) async throws {
        guard let url = buildURL(path: "/api/routing/equalizer/\(enabled)") else {
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
        guard let url = buildURL(path: "/api/volume/status") else {
            throw APIError.invalidURL
        }
        
        let (data, response) = try await session.data(from: url)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
        
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataDict = json["data"] as? [String: Any] else {
            throw APIError.invalidResponse
        }
        
        return VolumeStatus(
            volume: dataDict["volume"] as? Int ?? 0,
            mode: dataDict["mode"] as? String ?? "unknown",
            multiroomEnabled: dataDict["multiroom_enabled"] as? Bool ?? false
        )
    }
    
    func setVolume(_ volume: Int) async throws {
        guard let url = buildURL(path: "/api/volume/set") else {
            throw APIError.invalidURL
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
        let body: [String: Any] = ["volume": volume, "show_bar": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        
        let (_, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
    }
    
    func adjustVolume(_ delta: Int) async throws {
        guard let url = buildURL(path: "/api/volume/adjust") else {
            throw APIError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["delta": delta, "show_bar": false]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw APIError.httpError
        }
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
