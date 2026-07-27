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
///
/// `favicon` est le logo de la station : vide/absent pour beaucoup de favoris,
/// sinon soit une image hébergée par le Pi (`/api/radio/images/…`), soit une URL
/// externe à faire passer par le proxy backend. La résolution en URL absolue
/// vit dans `MiloAPIService.radioFaviconURL(for:)`, qui reprend la règle du
/// frontend Milō (utils/faviconUrl.js).
struct RadioStation: Decodable {
    let id: String
    let name: String
    let favicon: String?
}

private struct RadioStationsResponse: Decodable {
    let stations: [RadioStation]
}

// MARK: - Music Library

/// Morceau tel que servi par `/api/music-library/search` (dict Subsonic `song`, passé par
/// `search3`). `raw` garde le dict TEL QUEL : `play_context` (voir `playMusicLibraryContext`)
/// l'exige en retour, verbatim, comme contexte de file de lecture — le réduire à `id`/`title`/
/// `artist`/`coverArt` perdrait des champs que le backend attend.
struct MusicLibrarySong: Sendable, Identifiable {
    let id: String
    let title: String
    let artist: String?
    let coverArt: String?
    let raw: [String: any Sendable]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        title = json["title"] as? String ?? ""
        artist = json["artist"] as? String
        coverArt = json["coverArt"] as? String
        raw = JSONSendable.dictionary(json)
    }
}

/// Album tel que servi par `/api/music-library/search` (dict Subsonic `album`). Affiché en
/// lecture seule ici — pas de vue de navigation par album dans cette app.
struct MusicLibraryAlbum: Sendable, Identifiable {
    let id: String
    let name: String
    let artist: String?
    let coverArt: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = json["name"] as? String ?? json["title"] as? String ?? ""
        artist = json["artist"] as? String
        coverArt = json["coverArt"] as? String
    }
}

/// Artiste tel que servi par `/api/music-library/search` (dict Subsonic `artist`). Affiché en
/// lecture seule ici — pas de vue de navigation par artiste dans cette app.
struct MusicLibraryArtist: Sendable, Identifiable {
    let id: String
    let name: String
    let albumCount: Int?
    let coverArt: String?

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = json["name"] as? String ?? ""
        albumCount = json["albumCount"] as? Int
        coverArt = json["coverArt"] as? String ?? json["artistImageUrl"] as? String
    }
}

/// Résultat complet d'une recherche (`search3` : artistes/albums/morceaux fuzzy-matchés).
struct MusicLibrarySearchResults: Sendable {
    let artists: [MusicLibraryArtist]
    let albums: [MusicLibraryAlbum]
    let songs: [MusicLibrarySong]

    static let empty = MusicLibrarySearchResults(artists: [], albums: [], songs: [])

    var isEmpty: Bool { artists.isEmpty && albums.isEmpty && songs.isEmpty }

    init(artists: [MusicLibraryArtist], albums: [MusicLibraryAlbum], songs: [MusicLibrarySong]) {
        self.artists = artists
        self.albums = albums
        self.songs = songs
    }

    init(json: [String: Any]) {
        artists = (json["artists"] as? [[String: Any]] ?? []).compactMap(MusicLibraryArtist.init)
        albums = (json["albums"] as? [[String: Any]] ?? []).compactMap(MusicLibraryAlbum.init)
        songs = (json["songs"] as? [[String: Any]] ?? []).compactMap(MusicLibrarySong.init)
    }
}

// MARK: - Multiroom

/// Un client multiroom — un haut-parleur milo-client, ou le client local du Pi — tel que
/// servi par `/api/multiroom/state`. `Sendable` : décodé hors du main actor (pool
/// Swift-concurrency) puis remis au store, qui le possède.
///
/// L'identité canonique est le `mac_id` (le backend indexe tout dessus). `volumeControl`
/// vaut faux pour une carte DAC / un ampli externe qui gère son propre volume — le futur
/// slider n'a alors pas de prise, comme sur le frontend web.
struct MultiroomClient: Sendable, Identifiable {
    let macId: String
    let name: String
    let online: Bool
    let zoneId: String?
    let volumeDb: Double
    let mute: Bool
    let volumeControl: Bool
    let isLocal: Bool

    var id: String { macId }

    init?(json: [String: Any]) {
        guard let macId = json["mac_id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.macId = macId
        self.name = name
        online = json["online"] as? Bool ?? false
        zoneId = json["zone_id"] as? String
        volumeDb = (json["volume_db"] as? Double)
            ?? (json["volume_db"] as? Int).map(Double.init)
            ?? VolumeDefaults.limitMinDb
        mute = json["mute"] as? Bool ?? false
        volumeControl = json["volume_control"] as? Bool ?? true
        isLocal = (json["ip"] as? String) == "127.0.0.1"
    }
}

/// Une zone multiroom : un groupe de clients liés, avec un nom et l'ordre de ses membres
/// (`client_ids`, déjà triés client-local-d'abord par le backend).
struct MultiroomZone: Sendable, Identifiable {
    let id: String
    let name: String
    let clientIds: [String]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String,
              let name = json["name"] as? String else { return nil }
        self.id = id
        self.name = name
        clientIds = json["client_ids"] as? [String] ?? []
    }
}

/// Instantané complet du registre multiroom (`/api/multiroom/state`), clients et zones
/// indexés par leur identifiant. C'est la *structure* : noms, appartenance aux zones,
/// présence en ligne. Le volume/mute en direct arrive à part, par l'événement WebSocket
/// `volume/volume_changed` (voir Étape 2).
struct MultiroomSnapshot: Sendable {
    let clients: [String: MultiroomClient]   // indexés par mac_id
    let zones: [String: MultiroomZone]       // indexés par zone_id

    static let empty = MultiroomSnapshot(clients: [:], zones: [:])

    init(clients: [String: MultiroomClient], zones: [String: MultiroomZone]) {
        self.clients = clients
        self.zones = zones
    }

    init(json: [String: Any]) {
        var clients: [String: MultiroomClient] = [:]
        for (mac, raw) in (json["clients"] as? [String: Any] ?? [:]) {
            if let dict = raw as? [String: Any], let client = MultiroomClient(json: dict) {
                clients[mac] = client
            }
        }

        var zones: [String: MultiroomZone] = [:]
        for (zid, raw) in (json["zones"] as? [String: Any] ?? [:]) {
            if let dict = raw as? [String: Any], let zone = MultiroomZone(json: dict) {
                zones[zid] = zone
            }
        }

        self.clients = clients
        self.zones = zones
    }
}

/// Volume/mute EN DIRECT par client et par zone, tel que porté par `/api/volume/state` et par
/// l'événement WebSocket `volume/volume_changed` (`data.state`). Distinct de la *structure*
/// (`MultiroomSnapshot`) : celle-ci dit qui existe et où, celui-ci dit où en est le volume.
///
/// La moyenne de zone (`averageVolumeDb`) est pré-calculée par le backend — le slider de zone
/// s'y cale, et ne recompose pas la moyenne des clients côté app.
struct MultiroomVolume: Sendable {
    struct Client: Sendable {
        let volumeDb: Double
        let mute: Bool
        /// Faux quand le client ne peut pas régler son volume (carte DAC / ampli externe).
        let available: Bool
    }

    struct Zone: Sendable {
        let averageVolumeDb: Double
        let allMuted: Bool
    }

    let clients: [String: Client]   // indexés par mac_id
    let zones: [String: Zone]       // indexés par zone_id

    static let empty = MultiroomVolume(clients: [:], zones: [:])

    init(clients: [String: Client], zones: [String: Zone]) {
        self.clients = clients
        self.zones = zones
    }

    /// Décode le `data`/`state` de `/api/volume/state` ou de `volume/volume_changed`.
    init(state: [String: Any]) {
        func double(_ any: Any?) -> Double? {
            (any as? Double) ?? (any as? Int).map(Double.init)
        }

        var clients: [String: Client] = [:]
        for (mac, raw) in (state["clients"] as? [String: Any] ?? [:]) {
            guard let dict = raw as? [String: Any] else { continue }
            clients[mac] = Client(
                volumeDb: double(dict["volume_db"]) ?? VolumeDefaults.limitMinDb,
                mute: dict["mute"] as? Bool ?? false,
                available: dict["available"] as? Bool ?? true
            )
        }

        var zones: [String: Zone] = [:]
        for (zid, raw) in (state["zones"] as? [String: Any] ?? [:]) {
            guard let dict = raw as? [String: Any] else { continue }
            zones[zid] = Zone(
                averageVolumeDb: double(dict["average_volume_db"]) ?? VolumeDefaults.limitMinDb,
                allMuted: dict["all_muted"] as? Bool ?? false
            )
        }

        self.clients = clients
        self.zones = zones
    }
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

    /// Transport générique d'une commande de lecture vers la source active — même route que le
    /// frontend web (`POST /api/audio/control/{source}`). N'émet que des commandes sans
    /// paramètre (pause/resume/next) : chaque source valide la commande contre sa propre table
    /// (`COMMANDS` côté Milo) et rejette tout le reste en 400, donc un identifiant de source qui
    /// ne les supporte pas (AirPlay, DLNA, Qobuz — récepteurs passifs sans télécommande) échoue
    /// proprement plutôt que d'agir sur la mauvaise source.
    func sendPlaybackCommand(_ command: String, to source: String) async throws {
        try await send("/api/audio/control/\(source)", method: "POST",
                       body: ["command": command, "data": [String: Any]()])
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

    // MARK: - Multiroom API

    /// Lit la structure multiroom complète (clients + zones). Servi par le registre, donc
    /// indépendant de l'état actif — on ne l'appelle toutefois que lorsque le multiroom est
    /// activé (voir `MiloStore.loadMultiroomState`).
    func fetchMultiroomState() async throws -> MultiroomSnapshot {
        MultiroomSnapshot(json: try await fetchJSON("/api/multiroom/state"))
    }

    /// Lit le volume/mute en direct par client et par zone (moyennes de zone incluses) depuis
    /// `/api/volume/state`. Amorce les sliders de la sous-section avant que le premier
    /// `volume/volume_changed` ne prenne le relais.
    func fetchMultiroomVolume() async throws -> MultiroomVolume {
        let json = try await fetchJSON("/api/volume/state")
        return MultiroomVolume(state: json["data"] as? [String: Any] ?? [:])
    }

    /// Le backend indexe les clients par MAC AVEC deux-points ; l'URL les veut SANS.
    private static func macURL(_ macId: String) -> String {
        macId.replacingOccurrences(of: ":", with: "")
    }

    /// Fixe le volume ABSOLU d'un client (dB). `PATCH /api/volume/client/mac/{mac}`.
    func setClientVolume(mac: String, volumeDb: Double) async throws {
        try await send("/api/volume/client/mac/\(Self.macURL(mac))", method: "PATCH",
                       body: ["volume_db": volumeDb])
    }

    /// Bascule le mute d'un client. `PATCH /api/volume/client/mac/{mac}/mute`.
    func setClientMute(mac: String, muted: Bool) async throws {
        try await send("/api/volume/client/mac/\(Self.macURL(mac))/mute", method: "PATCH",
                       body: ["mute": muted])
    }

    /// Applique un DELTA de volume à toute une zone. `PATCH /api/volume/zone/{id}`.
    ///
    /// La zone n'a pas de volume propre : le backend répercute le delta sur chaque client et
    /// rediffuse la nouvelle moyenne. C'est pourquoi le slider de zone travaille en relatif
    /// (voir `MultiroomZoneRow`), là où celui d'un client est absolu.
    func setZoneVolumeDelta(zoneId: String, deltaDb: Double) async throws {
        try await send("/api/volume/zone/\(zoneId)", method: "PATCH",
                       body: ["delta_db": deltaDb])
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

    /// Résout le `favicon` d'une station en URL absolue affichable.
    ///
    /// Reprend la logique du frontend Milō (`utils/faviconUrl.js`) : une image
    /// locale (`/api/radio/images/…`) est servie telle quelle ; une URL externe
    /// passe par le proxy `/api/radio/favicon?url=…`, qui spoofe les en-têtes
    /// pour contourner les WAF qui rejettent un fetch brut. `nil` si le favori
    /// n'a pas de logo — l'appelant affiche alors son fallback.
    func radioFaviconURL(for favicon: String?) -> URL? {
        guard let favicon, !favicon.isEmpty else { return nil }
        let hostToUse = state.withLock { $0.resolvedIPv4 } ?? host
        let base = "http://\(hostToUse):\(port)"
        if favicon.hasPrefix("/api/radio/images/") {
            return URL(string: base + favicon)
        }
        var comps = URLComponents(string: "\(base)/api/radio/favicon")
        comps?.queryItems = [URLQueryItem(name: "url", value: favicon)]
        return comps?.url
    }

    func playRadioStation(_ stationId: String) async throws {
        try await send("/api/radio/play", method: "POST",
                       body: ["station_id": stationId])
    }

    func stopRadioPlayback() async throws {
        try await send("/api/radio/stop", method: "POST")
    }

    // MARK: - Music Library API

    /// Recherche fuzzy artistes/albums/morceaux (`search3`). Une requête vide renvoie trois
    /// listes vides en 200, pas une erreur — le backend le garantit.
    ///
    /// `URLComponents` (et non une concaténation à la main, comme pour `favorites_only=true`
    /// plus haut) : un terme de recherche, contrairement à un littéral fixe, a vraiment besoin
    /// d'être pourcent-encodé (espaces, accents…).
    func searchMusicLibrary(query: String) async throws -> MusicLibrarySearchResults {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let json = try await fetchJSON("/api/music-library/search?\(components.percentEncodedQuery ?? "")")
        return MusicLibrarySearchResults(json: json)
    }

    /// Lance la lecture d'une file de morceaux (`play_context`), à partir de l'index `startIndex`
    /// — même route générique que `sendPlaybackCommand`, mais avec des données, d'où une méthode à
    /// part plutôt qu'un paramètre optionnel de plus sur celle-ci.
    ///
    /// `[String: any Sendable]` (et non `[String: Any]`) : ce paramètre franchit la frontière
    /// d'isolation depuis le main actor (voir `MusicLibrarySong.raw`) — `Any` ferait échouer la
    /// vérification stricte de concurrence à l'appel. La conversion vers `Any` (ce que
    /// `JSONSerialization` exige) reste locale à cette méthode, qui ne franchit plus rien après.
    func playMusicLibraryContext(tracks: [[String: any Sendable]], startIndex: Int) async throws {
        let jsonTracks = tracks.map { $0.mapValues { $0 as Any } }
        try await send("/api/audio/control/music_library", method: "POST",
                       body: ["command": "play_context",
                              "data": ["tracks": jsonTracks, "start_index": startIndex, "shuffle": false]])
    }

    /// Résout l'identifiant de pochette Subsonic (`coverArt`) d'un résultat de recherche en URL
    /// affichable, via le proxy `/api/music-library/cover/{id}` (voir `nowPlayingArtworkURL` pour
    /// le même principe de résolution IP).
    func musicLibraryCoverURL(for coverId: String?, size: Int = 64) -> URL? {
        guard let coverId, !coverId.isEmpty else { return nil }
        let hostToUse = state.withLock { $0.resolvedIPv4 } ?? host
        var comps = URLComponents(string: "http://\(hostToUse):\(port)/api/music-library/cover/\(coverId)")
        comps?.queryItems = [URLQueryItem(name: "size", value: String(size))]
        return comps?.url
    }

    /// Albums d'un artiste (`getArtist`), pour la page artiste de la bibliothèque musicale.
    /// Mêmes objets « album » que ceux de la recherche (le backend passe les deux par
    /// `merge_albums`), donc `MusicLibraryAlbum` se réutilise tel quel. Le backend les range
    /// sous la clé Subsonic `"album"` (singulier), imbriquée sous `"artist"`.
    func fetchMusicLibraryArtistAlbums(artistId: String) async throws -> [MusicLibraryAlbum] {
        guard let encodedId = artistId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw APIError.invalidURL
        }
        let json = try await fetchJSON("/api/music-library/artist/\(encodedId)")
        let artist = json["artist"] as? [String: Any] ?? [:]
        return (artist["album"] as? [[String: Any]] ?? []).compactMap(MusicLibraryAlbum.init)
    }

    /// Morceaux d'un album (`getAlbum`), pour la page album de la bibliothèque musicale. `id`
    /// peut être le synthétique `mdisc:…` d'un album multi-disque fusionné — le backend l'étend
    /// (concatène les morceaux des disques membres) de façon transparente, rien à faire ici. La
    /// clé Subsonic du côté morceaux est `"song"` (singulier), imbriquée sous `"album"`.
    func fetchMusicLibraryAlbumSongs(albumId: String) async throws -> [MusicLibrarySong] {
        guard let encodedId = albumId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw APIError.invalidURL
        }
        let json = try await fetchJSON("/api/music-library/album/\(encodedId)")
        let album = json["album"] as? [String: Any] ?? [:]
        return (album["song"] as? [[String: Any]] ?? []).compactMap(MusicLibrarySong.init)
    }

    // MARK: - Now playing

    /// Résout `album_art_url` (ou l'artwork Shazam de Radio) en URL absolue affichable.
    ///
    /// Deux formes en sortie du backend (voir `PlaybackMetadata`, côté Milo) : un chemin LOCAL
    /// que le Pi sert lui-même (AirPlay, DLNA, CD, bibliothèque musicale — ex.
    /// `/api/dlna/artwork?v=…`), à préfixer d'host:port comme le reste de l'API ; ou une URL déjà
    /// absolue vers un CDN externe (Spotify, Qobuz, artwork Shazam reconnu par Radio), à utiliser
    /// telle quelle. `nil` si la métadonnée n'a pas d'illustration.
    func nowPlayingArtworkURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        let hostToUse = state.withLock { $0.resolvedIPv4 } ?? host
        return URL(string: "http://\(hostToUse):\(port)\(path)")
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
