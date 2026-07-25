import Foundation

/// Pilote les sliders et les mutes du sous-menu multiroom.
///
/// Trois responsabilités, chacune reprise du frontend web mais adaptée aux
/// contraintes AppKit :
///
/// 1. **Throttle par cible.** Chaque zone / client a sa propre cadence : premier
///    mouvement envoyé tout de suite, les suivants regroupés. Sans ça, un drag
///    produit une requête par pixel.
/// 2. **Valeur locale optimiste.** Le slider affiche la valeur choisie par
///    l'utilisateur jusqu'à ce que le backend la confirme (à ±1 dB) ou que le
///    filet de 2 s tombe — sinon chaque écho WebSocket ferait reculer le pouce.
/// 3. **Servo de delta pour les zones.** `/api/volume/zone/{id}` prend un DELTA,
///    pas une valeur absolue. On mémorise la moyenne serveur au début du geste
///    (l'ancre) et le cumul déjà envoyé, et on n'envoie que le reliquat — ce qui
///    rend l'envoi idempotent même quand le backend n'a pas encore rediffusé la
///    nouvelle moyenne. (Le frontend web relit la moyenne à chaque tick, ce qui
///    le rend sensible à cette course.)
///
/// Comme `VolumeController`, l'instance vit sur le main thread : tout son état
/// n'y est touché que là, et les continuations des requêtes y repassent
/// explicitement.
final class MultiroomVolumeController {
    enum Target: Hashable {
        case zone(String)     // zone_id
        case client(String)   // mac_id (avec deux-points)
    }

    weak var apiService: MiloAPIService?

    /// Appelé après chaque changement d'état local pour rafraîchir l'affichage.
    var onNeedsRefresh: (() -> Void)?

    // MARK: - État

    /// Valeur affichée en attendant la confirmation du backend.
    private var localVolumes: [Target: Double] = [:]
    private var localMutes: [Target: Bool] = [:]

    /// Ancre du servo de zone : moyenne serveur de référence + cumul envoyé.
    /// Sa durée de vie est celle de la valeur locale de la zone : tant qu'une
    /// valeur est en attente, l'ancre doit rester, sinon un second geste
    /// repartirait d'une moyenne serveur périmée et enverrait un delta faux.
    private var zoneAnchors: [String: (anchor: Double, sent: Double)] = [:]

    private var pendingVolumes: [Target: Double] = [:]
    private var lastSentAt: [Target: Date] = [:]
    private var debounceItems: [Target: DispatchWorkItem] = [:]
    private var fallbackItems: [Target: DispatchWorkItem] = [:]

    private var lastInteractionAt: Date?

    // MARK: - Constantes

    /// Cadences du frontend web : les zones coûtent N écritures côté backend,
    /// les clients une seule.
    private let zoneThrottle: TimeInterval = 0.08
    private let clientThrottle: TimeInterval = 0.05
    /// Au-delà, on considère que le geste est terminé.
    private let interactionTimeout: TimeInterval = 0.3
    /// Filet quand la confirmation n'arrive jamais (valeur bornée côté backend,
    /// client hors ligne…) : on rend la main au serveur.
    private let confirmationFallback: TimeInterval = 2.0
    /// Tolérance de confirmation — le backend arrondit et borne.
    private let confirmationTolerance: Double = 1.0

    /// Vrai tant qu'un geste est en cours : `MenuBarController` s'en sert pour
    /// différer la reconstruction du menu, qui détruirait le slider manipulé.
    var isUserInteracting: Bool {
        guard let last = lastInteractionAt else { return false }
        return Date().timeIntervalSince(last) < interactionTimeout
    }

    // MARK: - Lecture

    /// Valeur à afficher : la locale si un geste est en attente de confirmation,
    /// sinon celle du serveur.
    func displayVolume(for target: Target, serverValue: Double) -> Double {
        localVolumes[target] ?? serverValue
    }

    func displayMute(for target: Target, serverValue: Bool) -> Bool {
        localMutes[target] ?? serverValue
    }

    // MARK: - Écriture

    /// - Parameter serverValue: la valeur backend courante de la cible, utilisée
    ///   pour ancrer le servo au tout début d'un geste sur une zone.
    func handleVolumeChange(target: Target, newValue: Double, serverValue: Double) {
        lastInteractionAt = Date()
        localVolumes[target] = newValue
        pendingVolumes[target] = newValue

        if case .zone(let zoneId) = target, zoneAnchors[zoneId] == nil {
            zoneAnchors[zoneId] = (anchor: serverValue, sent: 0)
        }

        scheduleConfirmationFallback(for: target)

        let throttle = throttleInterval(for: target)
        let elapsed = lastSentAt[target].map { Date().timeIntervalSince($0) }
        if elapsed == nil || elapsed! > throttle {
            flush(target)
        } else {
            scheduleFlush(target, after: throttle)
        }
    }

    func toggleMute(target: Target, currentlyMuted: Bool, zoneMembers: [String] = []) {
        let newMuted = !currentlyMuted
        localMutes[target] = newMuted
        scheduleConfirmationFallback(for: target)
        onNeedsRefresh?()

        guard let apiService else { return }

        switch target {
        case .client(let macId):
            Task {
                do {
                    try await apiService.setClientMute(macId: macId, mute: newMuted)
                } catch {
                    NSLog("❌ Multiroom mute %@ failed: %@", macId, error.localizedDescription)
                    await MainActor.run { self.clearLocalState(for: target) }
                }
            }

        case .zone:
            // Pas d'endpoint atomique pour le mute de zone : on écrit chaque
            // membre en ligne, en parallèle (même approche que le frontend web).
            Task {
                var anyFailed = false
                await withTaskGroup(of: Bool.self) { group in
                    for macId in zoneMembers {
                        group.addTask {
                            do {
                                try await apiService.setClientMute(macId: macId, mute: newMuted)
                                return true
                            } catch {
                                NSLog("❌ Multiroom zone mute %@ failed: %@", macId, error.localizedDescription)
                                return false
                            }
                        }
                    }
                    for await ok in group where !ok { anyFailed = true }
                }
                if anyFailed {
                    await MainActor.run { self.clearLocalState(for: target) }
                }
            }
        }
    }

    // MARK: - Réconciliation

    /// Confronte les valeurs locales à un nouvel état serveur et efface celles
    /// qu'il a rattrapées. Tant qu'une valeur locale survit, elle prime à
    /// l'affichage — c'est ce qui empêche le slider de sauter en arrière pendant
    /// un drag.
    func reconcile(with volumes: MultiroomVolumes) {
        for (target, localValue) in localVolumes {
            guard let serverValue = serverVolume(for: target, in: volumes) else { continue }
            if abs(serverValue - localValue) <= confirmationTolerance {
                localVolumes[target] = nil
                clearZoneAnchor(for: target)
                cancelFallback(for: target)
            }
        }

        for (target, localMute) in localMutes {
            guard let serverMute = serverMute(for: target, in: volumes) else { continue }
            if serverMute == localMute {
                localMutes[target] = nil
                if localVolumes[target] == nil { cancelFallback(for: target) }
            }
        }
    }

    func cleanup() {
        debounceItems.values.forEach { $0.cancel() }
        debounceItems.removeAll()
        fallbackItems.values.forEach { $0.cancel() }
        fallbackItems.removeAll()
        localVolumes.removeAll()
        localMutes.removeAll()
        zoneAnchors.removeAll()
        pendingVolumes.removeAll()
        lastSentAt.removeAll()
        lastInteractionAt = nil
    }

    // MARK: - Envoi

    private func throttleInterval(for target: Target) -> TimeInterval {
        if case .zone = target { return zoneThrottle }
        return clientThrottle
    }

    private func scheduleFlush(_ target: Target, after delay: TimeInterval) {
        debounceItems[target]?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.flush(target) }
        debounceItems[target] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func flush(_ target: Target) {
        debounceItems[target]?.cancel()
        debounceItems[target] = nil

        guard let value = pendingVolumes[target], let apiService else { return }
        lastSentAt[target] = Date()

        switch target {
        case .client(let macId):
            pendingVolumes[target] = nil
            Task {
                do {
                    try await apiService.setClientVolume(macId: macId, volumeDb: value)
                } catch {
                    NSLog("❌ Multiroom volume %@ failed: %@", macId, error.localizedDescription)
                    await MainActor.run { self.clearLocalState(for: target) }
                }
            }

        case .zone(let zoneId):
            guard var anchor = zoneAnchors[zoneId] else { return }
            // Reliquat : ce qui reste à envoyer pour atteindre la cible depuis
            // l'ancre, une fois déduit tout ce qu'on a déjà envoyé.
            let delta = (value - anchor.anchor) - anchor.sent
            guard abs(delta) > 0.01 else {
                pendingVolumes[target] = nil
                return
            }
            anchor.sent += delta
            zoneAnchors[zoneId] = anchor
            pendingVolumes[target] = nil

            Task {
                do {
                    try await apiService.applyZoneDelta(zoneId: zoneId, deltaDb: delta)
                } catch {
                    NSLog("❌ Multiroom zone delta %@ failed: %@", zoneId, error.localizedDescription)
                    await MainActor.run { self.clearLocalState(for: target) }
                }
            }
        }
    }

    // MARK: - Filet de confirmation

    private func scheduleConfirmationFallback(for target: Target) {
        fallbackItems[target]?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            // Le backend n'a jamais confirmé (valeur bornée à une limite, membre
            // hors ligne…) : on rend la main à l'état serveur.
            self.clearLocalState(for: target)
        }
        fallbackItems[target] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + confirmationFallback, execute: item)
    }

    private func cancelFallback(for target: Target) {
        fallbackItems[target]?.cancel()
        fallbackItems[target] = nil
    }

    private func clearLocalState(for target: Target) {
        localVolumes[target] = nil
        localMutes[target] = nil
        pendingVolumes[target] = nil
        clearZoneAnchor(for: target)
        cancelFallback(for: target)
        onNeedsRefresh?()
    }

    private func clearZoneAnchor(for target: Target) {
        if case .zone(let zoneId) = target { zoneAnchors[zoneId] = nil }
    }

    // MARK: - Accès à l'état serveur

    private func serverVolume(for target: Target, in volumes: MultiroomVolumes) -> Double? {
        switch target {
        case .zone(let id):     return volumes.zones[id]?.averageVolumeDb
        case .client(let mac):  return volumes.clients[mac]?.volumeDb
        }
    }

    private func serverMute(for target: Target, in volumes: MultiroomVolumes) -> Bool? {
        switch target {
        case .zone(let id):     return volumes.zones[id]?.allMuted
        case .client(let mac):  return volumes.clients[mac]?.mute
        }
    }
}
