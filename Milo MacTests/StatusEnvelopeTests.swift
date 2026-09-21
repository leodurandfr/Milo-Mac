import Testing
import Foundation
@testable import Milo

/// Regression for the bug: Milo-Mac only read the HTTP status, while Milō deliberately
/// serves some failures as 200 + `{"status": "error"}`. Two routes of the surface called
/// here carry that envelope, and neither was being read:
///
/// - `PUT /api/equalizer/target/local/enabled` — an equalizer refused by the target passed
///   for accepted, and its spinner span until the 10 s safety net.
/// - `GET /api/volume/state` — the failure presented as a missing `data`, hence as an EMPTY
///   state: `loadMultiroomState` then overwrote the known volumes with zero clients,
///   flattening the sliders of the multiroom sub-section.
///
/// Like `BulkSettingsBootstrapTests`, these tests drive a real `MiloStore` against a real
/// local HTTP server — the actual URLSession stack and parsing are what get exercised, not
/// a reimplementation. The NOMINAL path of these two routes was verified against the Pi
/// (200 + `status: "success"`); only the refusal, which cannot be commanded on a real
/// device, is tested against the stub.
@MainActor
@Suite(.serialized)
struct StatusEnvelopeTests {

    @Test("An equalizer refused with a 200 stops the spinner instead of leaving it running")
    func refusedEqualizerStopsSpinner() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.equalizerRefuses = true

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()
        try await waitUntil(timeout: 15) { store.state != nil }

        store.toggleFeature("equalizer")
        #expect(store.loadingStates["equalizer"] == true, "the spinner starts on the click")

        // It must fall through the error path — at the display floor (1.2 s), well below
        // the 10 s safety net that resolved it before the fix. That gap is what the 5 s
        // window measures.
        try await waitUntil(timeout: 5) { store.loadingStates["equalizer"] != true }
        #expect(store.loadingStates["equalizer"] != true)
    }

    @Test("A failing /api/volume/state does not empty the multiroom volumes already known")
    func failingVolumeStateKeepsLastKnownMultiroomVolume() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.multiroomEnabled = true

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        // Multiroom active: the store loads the structure AND the volumes on its own.
        try await waitUntil(timeout: 15) { !store.multiroomVolume.clients.isEmpty }
        #expect(store.multiroomVolume.clients[StubMiloBackend.clientMac]?.volumeDb
                == StubMiloBackend.clientVolumeDb)

        // The volume service fails, then the app reloads — which is what any structure
        // event does, such as opening the sub-section.
        let hitsBefore = backend.volumeStateHits
        backend.volumeStateFails = true
        store.loadMultiroomState()

        try await waitUntil(timeout: 10) { backend.volumeStateHits > hitsBefore }
        try await Task.sleep(nanoseconds: 300_000_000)   // let the failure propagate to the store

        #expect(store.multiroomVolume.clients[StubMiloBackend.clientMac]?.volumeDb
                == StubMiloBackend.clientVolumeDb,
                "the last known value must survive the failure, not be overwritten with emptiness")
    }

    // MARK: - Helper

    /// Waits for a condition to become true, letting the main run loop turn.
    private func waitUntil(timeout: TimeInterval,
                           _ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("condition not met after \(Int(timeout)) s", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
