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

    /// Dernier état serveur connu. On l'ancre ici plutôt que de le laisser capturer
    /// par la closure d'une ligne : la ligne n'est pas reconstruite pendant un
    /// geste, sa copie serait donc figée à l'état d'avant le drag.
    private var latestVolumes: MultiroomVolumes?

    /// Dernier geste **par cible**. Une granularité globale ne suffit pas : c'est
    /// elle qui décide si une valeur locale peut être effacée, et effacer celle
    /// d'une zone qu'on est en train de bouger casse son servo de delta.
    private var lastInteractionAt: [Target: Date] = [:]

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
        let now = Date()
        return lastInteractionAt.values.contains { now.timeIntervalSince($0) < interactionTimeout }
    }

    private func isInteracting(with target: Target) -> Bool {
        guard let last = lastInteractionAt[target] else { return false }
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

    /// - Parameter fallbackServerValue: valeur de repli pour ancrer le servo d'une
    ///   zone, utilisée seulement si l'état serveur courant ne dit rien de la
    ///   cible. On préfère toujours `latestVolumes`, qui est frais — la valeur que
    ///   porte la ligne date de sa construction, donc d'avant le geste.
    func handleVolumeChange(target: Target, newValue: Double, fallbackServerValue: Double) {
        lastInteractionAt[target] = Date()
        localVolumes[target] = newValue
        pendingVolumes[target] = newValue

        if case .zone(let zoneId) = target, zoneAnchors[zoneId] == nil {
            zoneAnchors[zoneId] = (anchor: currentServerVolume(for: target) ?? fallbackServerValue,
                                   sent: 0)
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

    /// Mémorise le nouvel état serveur, puis efface les valeurs locales qu'il a
    /// rattrapées. Tant qu'une valeur locale survit, elle prime à l'affichage —
    /// c'est ce qui empêche le slider de sauter en arrière pendant un drag.
    func syncWithServer(_ volumes: MultiroomVolumes) {
        latestVolumes = volumes

        for (target, localValue) in localVolumes {
            // Un geste en cours sur cette cible interdit l'effacement. Effacer ici
            // emporterait aussi l'ancre du servo de zone, et le tick suivant
            // repartirait d'une référence pré-geste avec un cumul remis à zéro :
            // le delta déjà appliqué serait renvoyé une seconde fois et la zone
            // s'emballerait.
            guard !isInteracting(with: target) else { continue }
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
        lastInteractionAt.removeAll()
        latestVolumes = nil
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
            pendingVolumes[target] = nil
            // L'ancre a pu disparaître entre la programmation du flush et son
            // exécution (échec d'un envoi précédent, filet de confirmation). La
            // reconstruire depuis l'état serveur courant plutôt qu'abandonner :
            // sinon c'est la valeur de fin de geste qui est perdue et le slider
            // recule à la première réconciliation.
            var anchor = zoneAnchors[zoneId]
                ?? (anchor: currentServerVolume(for: target) ?? value, sent: 0)
            // Reliquat : ce qui reste à envoyer pour atteindre la cible depuis
            // l'ancre, une fois déduit tout ce qu'on a déjà envoyé.
            let delta = (value - anchor.anchor) - anchor.sent
            guard abs(delta) > 0.01 else {
                zoneAnchors[zoneId] = anchor
                return
            }
            anchor.sent += delta
            zoneAnchors[zoneId] = anchor

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
            self.fallbackItems[target] = nil
            // Un geste toujours en cours n'est pas une confirmation manquante :
            // sur un drag qui dure, le filet emporterait l'ancre du servo en
            // plein mouvement. On le repousse d'autant.
            guard !self.isInteracting(with: target) else {
                self.scheduleConfirmationFallback(for: target)
                return
            }
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

    private func currentServerVolume(for target: Target) -> Double? {
        latestVolumes.flatMap { serverVolume(for: target, in: $0) }
    }

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
