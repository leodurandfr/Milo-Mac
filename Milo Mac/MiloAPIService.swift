import Foundation
import Synchronization

/// Converts `JSONSerialization`'s `[String: Any]` into a genuinely **Sendable**
/// dictionary.
///
/// `MiloState` crosses an isolation boundary — it is decoded off the main actor
/// (URLSession's delegate queue for the WebSocket, the Swift-concurrency pool for HTTP)
/// and then handed to the main actor, which owns it. Its `metadata` therefore has to be
/// Sendable for real.
///
/// And not through an `as? [String: any Sendable]`: `Sendable` is a *marker* protocol,
/// with no runtime representation — that cast "always succeeds" without checking anything.
/// It would be an `@unchecked` in disguise. So we rebuild it explicitly, from the only
/// types `JSONSerialization` produces.
///
/// `NSNumber` values are kept as they are (they *are* Sendable): the rest of the app's
/// `as? Int` / `as? Bool` reads keep exactly the same Objective-C bridging behaviour as
/// with a `[String: Any]`.
enum JSONSendable {
    static func dictionary(_ raw: [String: Any]) -> [String: any Sendable] {
        raw.compactMapValues(value)
    }

    private static func value(_ any: Any) -> (any Sendable)? {
        switch any {
        case let number as NSNumber:      return number   // Int, Double and Bool
        case let string as String:        return string
        case let array as [Any]:          return array.compactMap(value)
        case let object as [String: Any]: return dictionary(object)
        default:                          return nil      // NSNull and unknowns
        }
    }
}

struct MiloState: Sendable {
    let activeSource: String
    let sourceState: String       // "starting", "ready", "active", "error"
    let transitioning: Bool       // true during a source change
    let multiroomEnabled: Bool
    let equalizerEnabled: Bool
    let metadata: [String: any Sendable]

    /// True when the source is SETTLED: its engine is running and nothing is in flight any
    /// more — the prerequisite for displaying any sub-level (radio stations, library search).
    ///
    /// `ready` is this state's current name on the backend side (`SourceState.READY`).
    /// `waiting` is the one it carried before the rename: we still accept it because a Milō
    /// that has not been updated still returns it, and both denote the same state (engine up,
    /// empty session). Do not narrow this to `ready` while the deployed backend may be old:
    /// that very mismatch is what made both chevrons disappear.
    var isSourceSettled: Bool {
        ["ready", "waiting", "active"].contains(sourceState.lowercased())
    }

    /// A single decoding of the backend payload — shared between the HTTP fetch
    /// (/api/audio/state) and the WebSocket events' `full_state`,
    /// so the two transports cannot diverge.
    init(json: [String: Any]) {
        activeSource = json["active_source"] as? String ?? "none"
        sourceState = json["source_state"] as? String ?? "active"
        transitioning = json["transitioning"] as? Bool ?? false
        multiroomEnabled = json["multiroom_enabled"] as? Bool ?? false
        equalizerEnabled = json["equalizer_effects_enabled"] as? Bool ?? true
        metadata = JSONSendable.dictionary(json["metadata"] as? [String: Any] ?? [:])
    }
}

/// Fallback volume bounds, used before the first /api/settings/bulk fetch
/// bootstraps the device's real limits.
/// A single definition for the menu slider, the HUD and the keyboard shortcut.
enum VolumeDefaults {
    static let limitMinDb = -80.0
    static let limitMaxDb = -21.0
}

struct VolumeStatus {
    let volumeDb: Double          // Volume in dB (-80 to 0)
    let multiroomEnabled: Bool
    let limitMinDb: Double        // Configured min limit
    let limitMaxDb: Double        // Configured max limit

    /// A copy with new bounds — used to preserve the cached limits
    /// when a WebSocket event does not carry any (see CLAUDE.md).
    func withLimits(minDb: Double, maxDb: Double) -> VolumeStatus {
        VolumeStatus(volumeDb: volumeDb,
                     multiroomEnabled: multiroomEnabled,
                     limitMinDb: minDb,
                     limitMaxDb: maxDb)
    }
}

/// The device's static settings, served in a single call by `/api/settings/bulk`
/// (replaces the old per-category volume-limits / dock-apps routes).
struct BulkSettings {
    let limitMinDb: Double
    let limitMaxDb: Double
    let enabledApps: [String]
}

/// A radio station as served by /api/radio/stations.
///
/// `favicon` is the station's logo: empty/absent for many favourites,
/// otherwise either an image hosted by the Pi (`/api/radio/images/…`), or an external
/// URL to route through the backend proxy. Resolving it to an absolute URL
/// lives in `MiloAPIService.radioFaviconURL(for:)`, which follows the
/// Milō frontend's rule (utils/faviconUrl.js).
struct RadioStation: Decodable {
    let id: String
    let name: String
    let favicon: String?
}

private struct RadioStationsResponse: Decodable {
    let stations: [RadioStation]
}

// MARK: - Music Library

/// A song as served by `/api/music-library/search` (a Subsonic `song` dict, passed through
/// `search3`). `raw` keeps the dict AS IS: `play_context` (see `playMusicLibraryContext`)
/// requires it back, verbatim, as the playback queue's context — reducing it to `id`/`title`/
/// `artist`/`coverArt` would lose fields the backend expects.
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

/// An album as served by `/api/music-library/search` (a Subsonic `album` dict). Displayed
/// read-only here — there is no album browsing view in this app.
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

/// An artist as served by `/api/music-library/search` (a Subsonic `artist` dict). Displayed
/// read-only here — there is no artist browsing view in this app.
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

/// The full result of a search (`search3`: fuzzy-matched artists/albums/songs).
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

/// A multiroom client — a milo-client speaker, or the Pi's local client — as
/// served by `/api/multiroom/state`. `Sendable`: decoded off the main actor (the
/// Swift-concurrency pool) and then handed to the store, which owns it.
///
/// The canonical identity is the `mac_id` (the backend indexes everything on it).
/// `volumeControl` is false for a DAC card / an external amp that manages its own volume —
/// the future slider then has no grip, as on the web frontend.
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

/// A multiroom zone: a group of linked clients, with a name and the order of its members
/// (`client_ids`, already sorted local-client-first by the backend).
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

/// A complete snapshot of the multiroom registry (`/api/multiroom/state`), clients and zones
/// indexed by their identifier. This is the *structure*: names, zone membership,
/// online presence. The live volume/mute arrives separately, through the WebSocket event
/// `volume/volume_changed` (see Step 2).
struct MultiroomSnapshot: Sendable {
    let clients: [String: MultiroomClient]   // indexed by mac_id
    let zones: [String: MultiroomZone]       // indexed by zone_id

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

/// LIVE volume/mute per client and per zone, as carried by `/api/volume/state` and by the
/// WebSocket event `volume/volume_changed` (`data.state`). Distinct from the *structure*
/// (`MultiroomSnapshot`): that one says who exists and where, this one says where the volume
/// stands.
///
/// The zone average (`averageVolumeDb`) is pre-computed by the backend — the zone slider
/// follows it, and does not recompose the clients' average on the app side.
struct MultiroomVolume: Sendable {
    struct Client: Sendable {
        let volumeDb: Double
        let mute: Bool
        /// False when the client cannot adjust its volume (DAC card / external amp).
        let available: Bool
    }

    struct Zone: Sendable {
        let averageVolumeDb: Double
        let allMuted: Bool
    }

    let clients: [String: Client]   // indexed by mac_id
    let zones: [String: Zone]       // indexed by zone_id

    static let empty = MultiroomVolume(clients: [:], zones: [:])

    init(clients: [String: Client], zones: [String: Zone]) {
        self.clients = clients
        self.zones = zones
    }

    /// Decodes the `data`/`state` of `/api/volume/state` or of `volume/volume_changed`.
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

/// Shared DNS → IPv4 resolution (a single CFHost block for the whole app).
/// MiloAPIService takes the first result; MiloConnectionManager keeps the
/// full list for its latency test. CFHost is soft-deprecated — the day
/// we migrate to Network.framework, this is the only place to change.
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
                    // Truncate at the terminating NUL then decode: `String(cString:)` is deprecated.
                    let bytes = hostname.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
                    let ipAddress = String(decoding: bytes, as: UTF8.self)
                    // Keep only the IPv4 addresses (no IPv6, which contains ":")
                    if !ipAddress.contains(":") {
                        results.append(ipAddress)
                    }
                }
            }
        }
        return results
    }
}

/// The Milō backend's HTTP client.
///
/// Unlike the rest of the app, this service is **not** main-thread-only: it is
/// called from the Swift-concurrency pool (all of its methods are `async`) and from a
/// utility DNS-resolution queue. Its correct treatment is therefore `Sendable`, not
/// `@MainActor`.
///
/// And a **checked** Sendable: all the mutable state is enclosed in a `Mutex`, and the
/// other properties are `let`s. Where an `NSLock` + `@unchecked Sendable` asked the
/// compiler to take our word for it, here it checks.
final class MiloAPIService: Sendable {
    private let host: String
    private let port: Int

    /// The mutable state, accessed from several threads — hence gathered under a single
    /// lock rather than scattered across `var` properties.
    private struct State {
        var session: URLSession
        // A session dedicated to the endpoints where the backend keeps the HTTP connection
        // open for the whole of a slow operation (e.g. the multiroom toggle: snapserver start
        // + source restart + volume push, up to ~20 s). The fast session's 3 s/5 s timeouts
        // would fire mid-transition.
        var longSession: URLSession
        var resolvedIPv4: String?
        // Volume limits: the device's static config, served by /api/settings/bulk.
        // Cached once at connect (via fetchBulkSettings) so that the volume
        // HUD does not pull the whole /bulk payload on every getVolumeStatus() —
        // which is what the Milō frontend does through its settingsStore.
        var cachedLimitMinDb: Double = VolumeDefaults.limitMinDb
        var cachedLimitMaxDb: Double = VolumeDefaults.limitMaxDb
    }

    private let state: Mutex<State>

    /// The cached bounds (bootstrapped by fetchBulkSettings, refreshed by the
    /// WebSocket settings/volume_limits_changed through updateCachedLimits).
    var cachedLimits: (minDb: Double, maxDb: Double) {
        state.withLock { ($0.cachedLimitMinDb, $0.cachedLimitMaxDb) }
    }

    /// - Parameter resolvedIPv4: an IP already validated by the caller (the connection
    ///   manager selects the best IP through a latency test). When it is
    ///   provided, we do not start an independent resolution that might
    ///   pick a different address from the one just probed.
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
        // A URLSession is only released once invalidated — indispensable for
        // the disposable instances (the connection manager's readiness probe).
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

    /// Recreates the sessions to avoid stale TCP connections
    func resetSession() {
        let old = state.withLock { state -> (URLSession, URLSession) in
            let previous = (state.session, state.longSession)
            state.session = Self.makeFastSession()
            state.longSession = Self.makeLongSession()
            return previous
        }

        old.0.invalidateAndCancel()
        old.1.invalidateAndCancel()

        // Re-resolve the IP: if the session is stale, the address may be too.
        resolveIPv4InBackground()
    }

    /// Resolves the hostname to IPv4 in the background and caches the address.
    private func resolveIPv4InBackground() {
        let host = self.host
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let ip = IPv4Resolver.resolveAll(host: host).first else { return }
            self?.state.withLock { $0.resolvedIPv4 = ip }
            NSLog("✅ Resolved %@ to IPv4: %@", host, ip)
        }
    }

    /// The Pi's HTTP origin: the resolved IPv4 if we have it, the hostname otherwise.
    ///
    /// The single point of the host rule, shared between `buildURL` — hence the whole `send`
    /// surface — and this file's three IMAGE URL builders (`radioFaviconURL`,
    /// `musicLibraryCoverURL`, `nowPlayingArtworkURL`).
    ///
    /// Those three do NOT go through `send`, and that is deliberate: they issue no request.
    /// They return a URL that `AsyncImage` will fetch itself, with SwiftUI's shared session —
    /// hence neither `send`'s 3 s timeout (too short for a cover a Pi pulls off an SD card),
    /// nor its typed errors (an image's failure is the view's placeholder, not an `APIError`
    /// to report), nor its disabled cache (a cover is precisely something we want to keep —
    /// see also `FaviconCache`). The only thing these URLs owe `send` is the host: which is
    /// exactly what this property gives them.
    private var baseURL: String {
        let hostToUse = state.withLock { $0.resolvedIPv4 } ?? host
        return "http://\(hostToUse):\(port)"
    }

    /// Builds the URL using the IPv4 address when available
    private func buildURL(path: String) -> URL? {
        URL(string: baseURL + path)
    }

    // MARK: - Generic request

    /// Builds, runs and validates a request; returns the response body.
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

    /// Like `send`, but ALSO validates the body's `status` — the second half of the contract,
    /// for every MUTATION.
    ///
    /// A 200 is not enough to conclude: Milō deliberately serves some failures as
    /// 200 + `{"status": "error"}` — `POST /api/audio/source/{id}` when the transition fails,
    /// `PUT /api/equalizer/target/{t}/enabled` when the target refuses. This is an API invariant
    /// documented on the backend side, not an oversight: it will not change, so it is up to the
    /// caller to read the body. Without this, a toggle that failed shows up as succeeded.
    ///
    /// Applied to ALL mutations, and not only to the routes known to do it: the cost is parsing
    /// a few bytes, and a route that adopted the envelope later would not have to be rediscovered
    /// through a button that lies. A body with no `status` key (or that is not JSON) passes:
    /// those routes report through the HTTP status, already validated by `send`.
    @discardableResult
    private func sendCommand(_ path: String,
                             method: String,
                             body: [String: Any]? = nil,
                             long: Bool = false) async throws -> Data {
        let data = try await send(path, method: method, body: body, long: long)
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let status = json["status"] as? String, status != "success" {
            throw APIError.backendError(status)
        }
        return data
    }

    // MARK: - Audio API

    func fetchState() async throws -> MiloState {
        MiloState(json: try await fetchJSON("/api/audio/state"))
    }

    func changeSource(_ source: String) async throws {
        try await sendCommand("/api/audio/source/\(source)", method: "POST")
    }

    func setMultiroom(_ enabled: Bool) async throws {
        // The backend blocks until the transition is fully complete (~20 s max).
        try await sendCommand("/api/routing/multiroom", method: "PUT",
                              body: ["enabled": enabled], long: true)
    }

    // MARK: - Volume API

    /// Reads the `data` of `/api/volume/state` — the only volume read route, shared
    /// by the global volume and by the multiroom volume.
    ///
    /// It carries the `{"status", "data"}` envelope, and the backend serves its failures there
    /// as 200 + `{"status": "error", "message": …}` (the same invariant as for mutations, see
    /// `sendCommand`). So it has to be read: without that, the failure presents as a missing
    /// `data`, that is, as an EMPTY state — 0 dB for the global volume, zero clients for
    /// multiroom. Plausible and wrong values, where an error lets the caller keep
    /// the last known value.
    private func fetchVolumeStateData() async throws -> [String: Any] {
        let json = try await fetchJSON("/api/volume/state")
        if let status = json["status"] as? String, status != "success" {
            throw APIError.backendError(json["message"] as? String ?? status)
        }
        guard let data = json["data"] as? [String: Any] else {
            throw APIError.invalidResponse
        }
        return data
    }

    /// Reads the volume value + the live mode. The limits come from the
    /// cache bootstrapped by fetchBulkSettings() at connect. The step is no longer
    /// carried: the keyboard shortcut's step is a local setting
    /// (GlobalHotkeyManager.volumeDeltaDb).
    func getVolumeStatus() async throws -> VolumeStatus {
        let dataDict = try await fetchVolumeStateData()

        // No default value here: a payload with no global_volume_db
        // would fabricate 0 dB (the maximum) — we prefer to fail cleanly.
        guard let volumeDb = (dataDict["global_volume_db"] as? Double)
                ?? (dataDict["global_volume_db"] as? Int).map(Double.init) else {
            throw APIError.invalidResponse
        }

        let mode = dataDict["mode"] as? String ?? "direct"
        let limits = cachedLimits

        return VolumeStatus(
            volumeDb: volumeDb,
            multiroomEnabled: mode == "multiroom",
            limitMinDb: limits.minDb,
            limitMaxDb: limits.maxDb
        )
    }

    func adjustVolumeDb(_ deltaDb: Double) async throws {
        try await sendCommand("/api/volume/adjust", method: "POST",
                              body: ["delta_db": deltaDb, "show_bar": true])
    }

    // MARK: - DSP API

    func setEqualizer(_ enabled: Bool) async throws {
        try await sendCommand("/api/equalizer/target/local/enabled", method: "PUT",
                              body: ["enabled": enabled])
    }

    /// Generic transport for a playback command to the active source — the same route as the
    /// web frontend (`POST /api/audio/control/{source}`). It only issues parameterless commands
    /// (pause/resume/next): each source validates the command against its own table
    /// (`COMMANDS` on the Milo side) and rejects everything else with a 400, so a source id that
    /// does not support them (AirPlay, DLNA, Qobuz — passive receivers with no remote) fails
    /// cleanly rather than acting on the wrong source.
    func sendPlaybackCommand(_ command: String, to source: String) async throws {
        try await sendCommand("/api/audio/control/\(source)", method: "POST",
                              body: ["command": command, "data": [String: Any]()])
    }

    // MARK: - Settings API

    /// Fetches the device's static settings (volume limits + dock apps) in a
    /// single call. Replaces the old per-category routes /api/settings/volume-limits
    /// and /api/settings/dock-apps — same sub-keys, different envelope:
    ///   volume-limits {"limits": {...}} → bulk {"volume_limits": {...}}
    ///   dock-apps     {"config": {...}} → bulk {"dock_apps": {...}}
    /// Side effect: bootstraps the limits cache read by getVolumeStatus().
    func fetchBulkSettings() async throws -> BulkSettings {
        let json = try await fetchJSON("/api/settings/bulk")

        // volume_limits.{min_db,max_db}: sub-keys identical to the old route;
        // we fall back on the current cache if the key is absent (never 0/0).
        let current = cachedLimits
        let limits = json["volume_limits"] as? [String: Any]
        let limitMin = (limits?["min_db"] as? Double) ?? (limits?["min_db"] as? Int).map(Double.init) ?? current.minDb
        let limitMax = (limits?["max_db"] as? Double) ?? (limits?["max_db"] as? Int).map(Double.init) ?? current.maxDb

        // dock_apps.enabled_apps: sub-key identical to the old route.
        let dockApps = json["dock_apps"] as? [String: Any]
        let enabledApps = dockApps?["enabled_apps"] as? [String] ?? []

        updateCachedLimits(minDb: limitMin, maxDb: limitMax)

        return BulkSettings(limitMinDb: limitMin, limitMaxDb: limitMax, enabledApps: enabledApps)
    }

    /// Updates the limits cache following the WS event `settings/volume_limits_changed`
    /// (the limits changed on the device side). getVolumeStatus() will read these new values
    /// — avoids re-pulling /bulk on every keyboard-shortcut sequence.
    func updateCachedLimits(minDb: Double, maxDb: Double) {
        state.withLock {
            $0.cachedLimitMinDb = minDb
            $0.cachedLimitMaxDb = maxDb
        }
    }

    // MARK: - Multiroom API

    /// Reads the full multiroom structure (clients + zones). Served by the registry, hence
    /// independent of the active state — we only call it when multiroom is
    /// enabled, though (see `MiloStore.loadMultiroomState`).
    func fetchMultiroomState() async throws -> MultiroomSnapshot {
        MultiroomSnapshot(json: try await fetchJSON("/api/multiroom/state"))
    }

    /// Reads the live volume/mute per client and per zone (zone averages included) from
    /// `/api/volume/state`. Bootstraps the sub-section's sliders before the first
    /// `volume/volume_changed` takes over.
    func fetchMultiroomVolume() async throws -> MultiroomVolume {
        MultiroomVolume(state: try await fetchVolumeStateData())
    }

    /// The backend indexes clients by MAC WITH colons; the URL wants them WITHOUT.
    private static func macURL(_ macId: String) -> String {
        macId.replacingOccurrences(of: ":", with: "")
    }

    /// Sets a client's ABSOLUTE volume (dB). `PATCH /api/volume/client/mac/{mac}`.
    func setClientVolume(mac: String, volumeDb: Double) async throws {
        try await sendCommand("/api/volume/client/mac/\(Self.macURL(mac))", method: "PATCH",
                              body: ["volume_db": volumeDb])
    }

    /// Toggles a client's mute. `PATCH /api/volume/client/mac/{mac}/mute`.
    func setClientMute(mac: String, muted: Bool) async throws {
        try await sendCommand("/api/volume/client/mac/\(Self.macURL(mac))/mute", method: "PATCH",
                              body: ["mute": muted])
    }

    /// Applies a volume DELTA to a whole zone. `PATCH /api/volume/zone/{id}`.
    ///
    /// A zone has no volume of its own: the backend passes the delta on to each client and
    /// rebroadcasts the new average. That is why the zone slider works in relative terms
    /// (see `MultiroomZoneRow`), where a client's is absolute.
    func setZoneVolumeDelta(zoneId: String, deltaDb: Double) async throws {
        try await sendCommand("/api/volume/zone/\(zoneId)", method: "PATCH",
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

    /// Resolves a station's `favicon` to an absolute, displayable URL.
    ///
    /// Follows the Milō frontend's logic (`utils/faviconUrl.js`): a local
    /// image (`/api/radio/images/…`) is served as is; an external URL
    /// goes through the `/api/radio/favicon?url=…` proxy, which spoofs the headers
    /// to get around WAFs that reject a raw fetch. `nil` if the favourite
    /// has no logo — the caller then shows its fallback.
    func radioFaviconURL(for favicon: String?) -> URL? {
        guard let favicon, !favicon.isEmpty else { return nil }
        let base = baseURL
        if favicon.hasPrefix("/api/radio/images/") {
            return URL(string: base + favicon)
        }
        var comps = URLComponents(string: "\(base)/api/radio/favicon")
        comps?.queryItems = [URLQueryItem(name: "url", value: favicon)]
        return comps?.url
    }

    func playRadioStation(_ stationId: String) async throws {
        try await sendCommand("/api/radio/play", method: "POST",
                              body: ["station_id": stationId])
    }

    func stopRadioPlayback() async throws {
        try await sendCommand("/api/radio/stop", method: "POST")
    }

    // MARK: - Music Library API

    /// Fuzzy search over artists/albums/songs (`search3`). An empty query returns three
    /// empty lists with a 200, not an error — the backend guarantees it.
    ///
    /// `URLComponents` (and not hand concatenation, as for `favorites_only=true`
    /// above): a search term, unlike a fixed literal, genuinely needs to be
    /// percent-encoded (spaces, accents…).
    func searchMusicLibrary(query: String) async throws -> MusicLibrarySearchResults {
        var components = URLComponents()
        components.queryItems = [URLQueryItem(name: "query", value: query)]
        let json = try await fetchJSON("/api/music-library/search?\(components.percentEncodedQuery ?? "")")
        return MusicLibrarySearchResults(json: json)
    }

    /// Starts playback of a queue of songs (`play_context`), from index `startIndex`
    /// — the same generic route as `sendPlaybackCommand`, but with data, hence a separate
    /// method rather than one more optional parameter on that one.
    ///
    /// `[String: any Sendable]` (and not `[String: Any]`): this parameter crosses the
    /// isolation boundary from the main actor (see `MusicLibrarySong.raw`) — `Any` would fail
    /// strict concurrency checking at the call site. The conversion to `Any` (which
    /// `JSONSerialization` requires) stays local to this method, which crosses nothing afterwards.
    func playMusicLibraryContext(tracks: [[String: any Sendable]], startIndex: Int) async throws {
        let jsonTracks = tracks.map { $0.mapValues { $0 as Any } }
        try await sendCommand("/api/audio/control/music_library", method: "POST",
                              body: ["command": "play_context",
                                     "data": ["tracks": jsonTracks, "start_index": startIndex, "shuffle": false]])
    }

    /// Resolves a search result's Subsonic cover identifier (`coverArt`) to a displayable
    /// URL, through the `/api/music-library/cover/{id}` proxy (see `nowPlayingArtworkURL` for
    /// the same IP-resolution principle).
    func musicLibraryCoverURL(for coverId: String?, size: Int = 64) -> URL? {
        guard let coverId, !coverId.isEmpty else { return nil }
        var comps = URLComponents(string: "\(baseURL)/api/music-library/cover/\(coverId)")
        comps?.queryItems = [URLQueryItem(name: "size", value: String(size))]
        return comps?.url
    }

    /// An artist's albums (`getArtist`), for the music library's artist page.
    /// The same "album" objects as the search's (the backend passes both through
    /// `merge_albums`), so `MusicLibraryAlbum` is reused as is. The backend files them
    /// under the Subsonic key `"album"` (singular), nested under `"artist"`.
    func fetchMusicLibraryArtistAlbums(artistId: String) async throws -> [MusicLibraryAlbum] {
        guard let encodedId = artistId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw APIError.invalidURL
        }
        let json = try await fetchJSON("/api/music-library/artist/\(encodedId)")
        let artist = json["artist"] as? [String: Any] ?? [:]
        return (artist["album"] as? [[String: Any]] ?? []).compactMap(MusicLibraryAlbum.init)
    }

    /// An album's songs (`getAlbum`), for the music library's album page. `id`
    /// can be the synthetic `mdisc:…` of a merged multi-disc album — the backend expands it
    /// (concatenating the member discs' songs) transparently, nothing to do here. The
    /// Subsonic key on the song side is `"song"` (singular), nested under `"album"`.
    func fetchMusicLibraryAlbumSongs(albumId: String) async throws -> [MusicLibrarySong] {
        guard let encodedId = albumId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw APIError.invalidURL
        }
        let json = try await fetchJSON("/api/music-library/album/\(encodedId)")
        let album = json["album"] as? [String: Any] ?? [:]
        return (album["song"] as? [[String: Any]] ?? []).compactMap(MusicLibrarySong.init)
    }

    /// One page of albums from a Subsonic list (`getAlbumList2`): `recent` (recently played),
    /// `newest` (recently added), `random`… The backend validates the type against its
    /// `ALBUM_LIST_TYPES` allow-list and answers 400 if it is not in it, hence the absence of a
    /// guard here — the only callers pass literals.
    ///
    /// These are the same "album" objects as the search's and the artist page's (the
    /// backend passes all three through `merge_albums`), so `MusicLibraryAlbum` is reused as
    /// is. No encoding to do: neither the type nor the size comes from user input.
    func fetchMusicLibraryAlbums(type: String, size: Int) async throws -> [MusicLibraryAlbum] {
        let json = try await fetchJSON("/api/music-library/albums?type=\(type)&size=\(size)")
        return (json["albums"] as? [[String: Any]] ?? []).compactMap(MusicLibraryAlbum.init)
    }

    // MARK: - Now playing

    /// Resolves `album_art_url` (or Radio's Shazam artwork) to an absolute, displayable URL.
    ///
    /// Two shapes come out of the backend (see `PlaybackMetadata`, on the Milo side): a LOCAL
    /// path the Pi serves itself (AirPlay, DLNA, CD, music library — e.g.
    /// `/api/dlna/artwork?v=…`), to be prefixed with host:port like the rest of the API; or an
    /// already absolute URL to an external CDN (Spotify, Qobuz, the Shazam artwork Radio
    /// recognized), to be used as is. `nil` if the metadata has no artwork.
    func nowPlayingArtworkURL(for path: String?) -> URL? {
        guard let path, !path.isEmpty else { return nil }
        if path.hasPrefix("http://") || path.hasPrefix("https://") {
            return URL(string: path)
        }
        return URL(string: baseURL + path)
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
