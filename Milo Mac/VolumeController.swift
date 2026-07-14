import Foundation

/// Envoi du volume vers le backend, avec debounce.
///
/// Ne connaît plus aucune vue : le slider SwiftUI écrit dans `MiloStore.sliderVolumeDb`
/// et appelle `handleVolumeChange`. La seule chose que ce contrôleur expose à l'UI est
/// `isUserInteracting`, qui sert à ne pas écraser la valeur que l'utilisateur est en
/// train de manipuler avec l'écho (retardé) du serveur.
///
/// Comme le reste de l'app, cette classe s'utilise exclusivement depuis le main thread —
/// et `@MainActor` le fait désormais vérifier par le compilateur, au lieu de le promettre
/// en commentaire.
@MainActor
final class VolumeController {
    weak var apiService: MiloAPIService?

    private var pendingVolumeDb: Double?
    private var lastVolumeAPICall: Date?
    private var volumeDebounceWorkItem: DispatchWorkItem?

    /// Lu par MiloStore pour ignorer l'écho serveur pendant que l'utilisateur
    /// fait glisser le slider (sinon la valeur locale et la valeur serveur,
    /// en retard, se disputent le contrôle).
    private(set) var isUserInteracting = false
    private var lastUserInteraction: Date?

    /// Dernière valeur connue du serveur : les commandes envoyées sont des
    /// deltas (`/api/volume/adjust`), pas des valeurs absolues, donc il faut
    /// une référence pour calculer l'écart.
    private var referenceVolumeDb: Double = 0

    private let volumeDebounceDelay: TimeInterval = 0.03
    private let volumeImmediateSendThreshold: TimeInterval = 0.1
    private let userInteractionTimeout: TimeInterval = 0.3

    func setCurrentVolume(_ volume: VolumeStatus) {
        // Le serveur est la source de vérité tant que l'utilisateur ne touche à rien.
        if !isUserInteracting {
            referenceVolumeDb = volume.volumeDb
        }
    }

    func handleVolumeChange(_ newVolumeDb: Double) {
        isUserInteracting = true
        lastUserInteraction = Date()
        pendingVolumeDb = newVolumeDb

        let now = Date()
        let shouldSendImmediately = lastVolumeAPICall == nil ||
                                    now.timeIntervalSince(lastVolumeAPICall!) > volumeImmediateSendThreshold

        if shouldSendImmediately {
            sendVolumeUpdate(newVolumeDb)
        } else {
            scheduleDelayedVolumeUpdate()
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + userInteractionTimeout) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let lastInteraction = self.lastUserInteraction else { return }

                if Date().timeIntervalSince(lastInteraction) >= self.userInteractionTimeout {
                    self.isUserInteracting = false
                }
            }
        }
    }

    func cleanup() {
        lastUserInteraction = nil
        isUserInteracting = false
        volumeDebounceWorkItem?.cancel()
        volumeDebounceWorkItem = nil
    }

    private func sendVolumeUpdate(_ volumeDb: Double) {
        guard let apiService else { return }

        let delta = volumeDb - referenceVolumeDb
        guard abs(delta) > 0.01 else { return }

        referenceVolumeDb = volumeDb
        lastVolumeAPICall = Date()

        // La classe est main-isolée : cette Task hérite du main actor, et `pendingVolumeDb`
        // se relit donc sur le main thread après l'await, sans MainActor.run explicite.
        Task {
            do {
                try await apiService.adjustVolumeDb(delta)
                if pendingVolumeDb == volumeDb {
                    pendingVolumeDb = nil
                }
            } catch {
                pendingVolumeDb = volumeDb
            }
        }
    }

    private func scheduleDelayedVolumeUpdate() {
        volumeDebounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let volumeDb = self.pendingVolumeDb else { return }
                self.sendVolumeUpdate(volumeDb)
            }
        }

        volumeDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + volumeDebounceDelay, execute: workItem)
    }
}
