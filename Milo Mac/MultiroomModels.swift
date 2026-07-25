import Foundation

// MARK: - Topologie (GET /api/multiroom/state)

/// Client Snapcast tel que servi par `/api/multiroom/state` (`Client.to_dict`
/// côté backend, avec les champs runtime `online` / `is_local`).
struct MultiroomClient {
    let macId: String          // avec deux-points : "dc:a6:32:7e:d3:43"
    let name: String
    let zoneId: String?
    let speakerType: String    // satellite | bookshelf | tower | subwoofer
    let volumeControl: Bool    // false = carte DAC, un ampli externe gère le volume
    let online: Bool
    let isLocal: Bool

    init?(json: [String: Any]) {
        guard let macId = json["mac_id"] as? String else { return nil }
        self.macId = macId
        name = (json["name"] as? String) ?? macId
        // `zone_id` est explicitement null pour un client isolé.
        zoneId = json["zone_id"] as? String
        speakerType = (json["speaker_type"] as? String) ?? "bookshelf"
        volumeControl = (json["volume_control"] as? Bool) ?? true
        online = (json["online"] as? Bool) ?? false
        isLocal = (json["is_local"] as? Bool) ?? false
    }
}

/// Zone (groupe de clients liés) telle que servie par `/api/multiroom/state`
/// (`zone_to_enriched_dict`). Seuls l'id, le nom et la composition nous servent :
/// les valeurs de volume viennent de `/api/volume/state`.
struct MultiroomZone {
    let id: String
    let name: String
    let clientIds: [String]

    init?(json: [String: Any]) {
        guard let id = json["id"] as? String else { return nil }
        self.id = id
        name = (json["name"] as? String) ?? id
        clientIds = (json["client_ids"] as? [String]) ?? []
    }
}

/// Composition du système multiroom. Le backend est la source de vérité : on ne
/// déduit jamais l'appartenance à une zone autrement que par `Client.zone_id` /
/// `Zone.client_ids`.
struct MultiroomTopology {
    var clients: [String: MultiroomClient]   // indexé par mac_id
    var zones: [String: MultiroomZone]       // indexé par zone_id

    static let empty = MultiroomTopology(clients: [:], zones: [:])

    init(clients: [String: MultiroomClient], zones: [String: MultiroomZone]) {
        self.clients = clients
        self.zones = zones
    }

    init(json: [String: Any]) {
        var clients: [String: MultiroomClient] = [:]
        for (macId, raw) in (json["clients"] as? [String: Any]) ?? [:] {
            guard let dict = raw as? [String: Any], let client = MultiroomClient(json: dict) else { continue }
            clients[macId] = client
        }

        var zones: [String: MultiroomZone] = [:]
        for (zoneId, raw) in (json["zones"] as? [String: Any]) ?? [:] {
            guard let dict = raw as? [String: Any], let zone = MultiroomZone(json: dict) else { continue }
            zones[zoneId] = zone
        }

        self.clients = clients
        self.zones = zones
    }
}

// MARK: - Volumes (GET /api/volume/state → data)

struct ClientVolume {
    let volumeDb: Double
    let mute: Bool

    init?(json: [String: Any]) {
        guard let db = Self.double(json["volume_db"]) else { return nil }
        volumeDb = db
        mute = (json["mute"] as? Bool) ?? false
    }

    fileprivate static func double(_ value: Any?) -> Double? {
        (value as? Double) ?? (value as? Int).map(Double.init)
    }
}

struct ZoneVolume {
    let averageVolumeDb: Double
    let allMuted: Bool

    init?(json: [String: Any]) {
        guard let db = ClientVolume.double(json["average_volume_db"]) else { return nil }
        averageVolumeDb = db
        allMuted = (json["all_muted"] as? Bool) ?? false
    }
}

/// Volumes par client et par zone. Les moyennes de zone sont **calculées par le
/// backend** — on ne les recalcule qu'en dernier recours (zone absente du
/// payload), contrairement au frontend web qui a un fallback systématique.
struct MultiroomVolumes {
    var clients: [String: ClientVolume]
    var zones: [String: ZoneVolume]

    static let empty = MultiroomVolumes(clients: [:], zones: [:])

    init(clients: [String: ClientVolume], zones: [String: ZoneVolume]) {
        self.clients = clients
        self.zones = zones
    }

    /// - Parameter data: l'objet `data` de `/api/volume/state`, ou le `state` d'un
    ///   événement WebSocket `volume/volume_changed` — même forme
    ///   (`VolumeState.to_dict()`), c'est pourquoi le décodage est partagé.
    init(volumeStateData data: [String: Any]) {
        var clients: [String: ClientVolume] = [:]
        for (macId, raw) in (data["clients"] as? [String: Any]) ?? [:] {
            guard let dict = raw as? [String: Any], let volume = ClientVolume(json: dict) else { continue }
            clients[macId] = volume
        }

        var zones: [String: ZoneVolume] = [:]
        for (zoneId, raw) in (data["zones"] as? [String: Any]) ?? [:] {
            guard let dict = raw as? [String: Any], let volume = ZoneVolume(json: dict) else { continue }
            zones[zoneId] = volume
        }

        self.clients = clients
        self.zones = zones
    }
}

// MARK: - Modèle d'affichage

/// Une enceinte, telle qu'affichée (isolée ou membre d'une zone dépliée).
struct MultiroomDisplayClient {
    let macId: String
    let name: String
    let speakerType: String
    let volumeDb: Double
    let muted: Bool
    let online: Bool
    /// false = carte DAC : le volume est géré par un ampli externe, pas de slider.
    let volumeControl: Bool

    var hasSlider: Bool { online && volumeControl }
}

/// Une zone, avec sa moyenne de volume et ses membres.
struct MultiroomDisplayZone {
    let id: String
    let name: String
    let volumeDb: Double
    let muted: Bool
    let clients: [MultiroomDisplayClient]

    /// Au moins un membre en ligne : une zone entièrement hors ligne reste
    /// affichée (elle existe côté backend) mais sans slider.
    var anyOnline: Bool { clients.contains { $0.online } }
    /// Tous les membres en ligne sont en mode DAC → volume géré à l'extérieur.
    /// Équivaut à `zone.all_external_volume` côté frontend web.
    var allExternalVolume: Bool {
        let onlineClients = clients.filter { $0.online }
        return !onlineClients.isEmpty && onlineClients.allSatisfy { !$0.volumeControl }
    }
    var hasSlider: Bool { anyOnline && !allExternalVolume }
    /// On ne propose le dépliage qu'à partir de deux membres — en dessous, la
    /// ligne de zone dit déjà tout (même règle que `canExpand` côté web).
    var isExpandable: Bool { clients.count > 1 }
}

enum MultiroomDisplayItem {
    case zone(MultiroomDisplayZone)
    case client(MultiroomDisplayClient)

    /// Identité stable d'une ligne, utilisée pour décider entre mutation en place
    /// et reconstruction du sous-menu (voir `MultiroomSubmenuController`).
    var identity: String {
        switch self {
        case .zone(let zone):     return "zone:\(zone.id)"
        case .client(let client): return "client:\(client.macId)"
        }
    }

    var displayName: String {
        switch self {
        case .zone(let zone):     return zone.name
        case .client(let client): return client.name
        }
    }
}

// MARK: - Construction du modèle d'affichage

enum MultiroomDisplayModel {
    /// Croise topologie et volumes pour produire la liste ordonnée des lignes.
    ///
    /// Ordre (identique au frontend web) : en ligne d'abord, puis zones avant
    /// clients isolés, puis alphabétique. Les membres d'une zone sont triés
    /// client local d'abord, puis en ligne, puis alphabétique.
    static func build(topology: MultiroomTopology,
                      volumes: MultiroomVolumes,
                      fallbackVolumeDb: Double) -> [MultiroomDisplayItem] {
        var items: [MultiroomDisplayItem] = []

        // Zones : on part de la topologie (source de vérité de la composition).
        for zone in topology.zones.values {
            let members = zone.clientIds
                .compactMap { topology.clients[$0] }
                .sorted(by: memberOrder)
                .map { displayClient($0, volumes: volumes, fallbackVolumeDb: fallbackVolumeDb) }

            // Une zone sans membre connu n'a rien à afficher (registre incohérent
            // le temps qu'un client_state_changed rattrape).
            guard !members.isEmpty else { continue }

            let zoneVolume = volumes.zones[zone.id]
            items.append(.zone(MultiroomDisplayZone(
                id: zone.id,
                name: zone.name,
                volumeDb: zoneVolume?.averageVolumeDb
                    ?? averageVolume(of: members, fallbackVolumeDb: fallbackVolumeDb),
                muted: zoneVolume?.allMuted ?? allMuted(members),
                clients: members
            )))
        }

        // Clients isolés : pas de zone_id, ou un zone_id orphelin (zone supprimée
        // dont le client n'a pas encore été rafraîchi).
        for client in topology.clients.values {
            if let zoneId = client.zoneId, topology.zones[zoneId] != nil { continue }
            items.append(.client(displayClient(client, volumes: volumes, fallbackVolumeDb: fallbackVolumeDb)))
        }

        return items.sorted(by: topLevelOrder)
    }

    // MARK: - Tri

    private static func memberOrder(_ a: MultiroomClient, _ b: MultiroomClient) -> Bool {
        if a.isLocal != b.isLocal { return a.isLocal }
        if a.online != b.online { return a.online }
        return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
    }

    private static func topLevelOrder(_ a: MultiroomDisplayItem, _ b: MultiroomDisplayItem) -> Bool {
        let aOnline = isOnline(a)
        let bOnline = isOnline(b)
        if aOnline != bOnline { return aOnline }

        let aIsZone = isZone(a)
        let bIsZone = isZone(b)
        if aIsZone != bIsZone { return aIsZone }

        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
    }

    private static func isOnline(_ item: MultiroomDisplayItem) -> Bool {
        switch item {
        case .zone(let zone):     return zone.anyOnline
        case .client(let client): return client.online
        }
    }

    private static func isZone(_ item: MultiroomDisplayItem) -> Bool {
        if case .zone = item { return true }
        return false
    }

    // MARK: - Helpers

    private static func displayClient(_ client: MultiroomClient,
                                      volumes: MultiroomVolumes,
                                      fallbackVolumeDb: Double) -> MultiroomDisplayClient {
        let volume = volumes.clients[client.macId]
        return MultiroomDisplayClient(
            macId: client.macId,
            name: client.name,
            speakerType: client.speakerType,
            volumeDb: volume?.volumeDb ?? fallbackVolumeDb,
            muted: volume?.mute ?? false,
            online: client.online,
            volumeControl: client.volumeControl
        )
    }

    /// Repli quand le backend n'a pas (encore) publié la moyenne d'une zone :
    /// moyenne arithmétique des seuls membres réglables, comme le frontend web.
    private static func averageVolume(of members: [MultiroomDisplayClient],
                                      fallbackVolumeDb: Double) -> Double {
        let controllable = members.filter { $0.hasSlider }
        guard !controllable.isEmpty else { return fallbackVolumeDb }
        return controllable.reduce(0.0) { $0 + $1.volumeDb } / Double(controllable.count)
    }

    private static func allMuted(_ members: [MultiroomDisplayClient]) -> Bool {
        let online = members.filter { $0.online }
        guard !online.isEmpty else { return false }
        return online.allSatisfy { $0.muted }
    }
}
