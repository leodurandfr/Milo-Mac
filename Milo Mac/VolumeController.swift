import AppKit
import Foundation

class VolumeController {
    weak var apiService: MiloAPIService?
    weak var activeMenu: NSMenu?

    private var pendingVolumeDb: Double?
    private var lastVolumeAPICall: Date?
    private var volumeDebounceWorkItem: DispatchWorkItem?
    private var isUserInteracting = false
    private var lastUserInteraction: Date?
    private var volumeSlider: NSSlider?
    private var currentVolume: VolumeStatus?

    private let volumeDebounceDelay: TimeInterval = 0.03
    private let volumeImmediateSendThreshold: TimeInterval = 0.1
    private let userInteractionTimeout: TimeInterval = 0.3

    // Limites de volume stockées séparément (mises à jour depuis l'API/WebSocket)
    private var limitMinDb: Double = -80.0
    private var limitMaxDb: Double = -21.0

    func setCurrentVolume(_ volume: VolumeStatus) {
        self.currentVolume = volume
        // Ne met à jour que la valeur, pas les limites
    }

    /// Met à jour les limites min/max du volume (appelé au démarrage et quand les limites changent)
    func updateVolumeLimits(minDb: Double, maxDb: Double) {
        self.limitMinDb = minDb
        self.limitMaxDb = maxDb
        if let slider = volumeSlider {
            slider.minValue = minDb
            slider.maxValue = maxDb
        }
    }

    func setVolumeSlider(_ slider: NSSlider) {
        self.volumeSlider = slider
        slider.minValue = limitMinDb
        slider.maxValue = limitMaxDb
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
            guard let self = self, let lastInteraction = self.lastUserInteraction else { return }

            if Date().timeIntervalSince(lastInteraction) >= self.userInteractionTimeout {
                self.isUserInteracting = false
            }
        }
    }

    func updateSliderFromWebSocket(_ volumeDb: Double) {
        guard let slider = volumeSlider, !isUserInteracting else { return }

        // Éviter les mises à jour inutiles (tolérance de 0.1 dB)
        if abs(slider.doubleValue - volumeDb) < 0.1 {
            return
        }

        // Désactiver temporairement l'action pour éviter les boucles
        let originalTarget = slider.target
        let originalAction = slider.action
        slider.target = nil
        slider.action = nil

        slider.doubleValue = volumeDb

        // Forcer la mise à jour visuelle du slider custom
        if let nativeSlider = slider as? NativeVolumeSlider {
            nativeSlider.needsDisplay = true
        }

        slider.target = originalTarget
        slider.action = originalAction
    }

    func cleanup() {
        // Nettoyer les états temporaires
        lastUserInteraction = nil
        isUserInteracting = false
        volumeDebounceWorkItem?.cancel()
        volumeDebounceWorkItem = nil
    }

    private func sendVolumeUpdate(_ volumeDb: Double) {
        guard let apiService = apiService else { return }
        guard activeMenu != nil || volumeSlider != nil else { return }

        lastVolumeAPICall = Date()

        Task {
            do {
                try await apiService.setVolumeDb(volumeDb)
                // Clear pending volume en cas de succès
                if self.pendingVolumeDb == volumeDb {
                    self.pendingVolumeDb = nil
                }
            } catch {
                // Garder la valeur en pending si échec
                self.pendingVolumeDb = volumeDb
            }
        }
    }

    private func scheduleDelayedVolumeUpdate() {
        volumeDebounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self = self, let volumeDb = self.pendingVolumeDb else { return }
            guard self.activeMenu != nil || self.volumeSlider != nil else { return }
            self.sendVolumeUpdate(volumeDb)
        }

        volumeDebounceWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + volumeDebounceDelay, execute: workItem)
    }
}
