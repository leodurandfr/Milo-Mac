import Foundation

/// Sends the volume to the backend, with debouncing.
///
/// It no longer knows about any view: the SwiftUI slider writes into
/// `MiloStore.sliderVolumeDb` and calls `handleVolumeChange`. The only thing this
/// controller exposes to the UI is `isUserInteracting`, which keeps the server's (delayed)
/// echo from overwriting the value the user is currently dragging.
///
/// Like the rest of the app, this class is used exclusively from the main thread — and
/// `@MainActor` now has the compiler check that, instead of promising it in a comment.
@MainActor
final class VolumeController {
    weak var apiService: MiloAPIService?

    private var pendingVolumeDb: Double?
    private var lastVolumeAPICall: Date?
    private var volumeDebounceWorkItem: DispatchWorkItem?

    /// Read by MiloStore to ignore the server echo while the user is dragging
    /// the slider (otherwise the local value and the lagging server value
    /// fight over control).
    private(set) var isUserInteracting = false
    private var lastUserInteraction: Date?

    /// Last value known to the server: the commands sent are deltas
    /// (`/api/volume/adjust`), not absolute values, so a reference point is
    /// needed to compute the difference.
    private var referenceVolumeDb: Double = 0

    private let volumeDebounceDelay: TimeInterval = 0.03
    private let volumeImmediateSendThreshold: TimeInterval = 0.1
    private let userInteractionTimeout: TimeInterval = 0.3

    func setCurrentVolume(_ volume: VolumeStatus) {
        // The server is the source of truth as long as the user touches nothing.
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

        // The class is main-isolated: this Task inherits the main actor, so `pendingVolumeDb`
        // is read back on the main thread after the await, with no explicit MainActor.run.
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
