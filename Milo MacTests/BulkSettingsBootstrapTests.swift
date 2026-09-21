import Testing
import Foundation
// The module follows PRODUCT_NAME ("Milo"), not the target name ("Milo Mac"):
// WRAPPER_NAME only renames the bundle (Milō.app).
@testable import Milo

/// Regression for the bug: a failed `/api/settings/bulk` at connect time was never retried.
/// `enabledApps` stayed nil for the whole connection (all 7 sources showed up with no
/// backend filter or order) and the volume limits stayed at the -80/-21 fallback.
///
/// The tests drive the real `MiloStore` against a real local HTTP server
/// (`StubMiloBackend`), calling the `MiloConnectionManagerDelegate` methods exactly the
/// way the connection layer does.
@MainActor
@Suite(.serialized)
struct BulkSettingsBootstrapTests {

    /// The background poll runs every 30 s; this test really waits it out.
    private static let backgroundRefreshInterval: TimeInterval = 30

    // MARK: - Bootstrap at connect

    @Test("A /bulk that fails then succeeds is retried at connect")
    func bootstrapRetriesUntilBulkSucceeds() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }

        // The first two calls fail: the old code only made one.
        backend.bulkFailuresRemaining = 2

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        // Wait for the volume TOO: the limits derive from it (`volumeLimits` returns the
        // fallback while `volume` is nil), and it is loaded by a separate call from /bulk.
        // Waiting only on `enabledApps` made this test flaky — it sometimes read the fallback
        // before /api/volume/state had come back.
        try await waitUntil(timeout: 15) { store.enabledApps != nil && store.volume != nil }

        #expect(store.enabledApps == StubMiloBackend.enabledApps)
        #expect(backend.bulkHits >= 3, "both failures must have been retried")
        // Real limits whatever the arrival order: /bulk first (the cache bootstraps
        // getVolumeStatus), or volume first (refreshBulkSettings realigns afterwards).
        #expect(store.volumeLimits.minDb == StubMiloBackend.limitMinDb)
        #expect(store.volumeLimits.maxDb == StubMiloBackend.limitMaxDb)
    }

    @Test("The sources are filtered and ordered by enabled_apps after a retried /bulk")
    func sourcesAreFilteredAfterRetriedBulk() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.bulkFailuresRemaining = 2

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        try await waitUntil(timeout: 15) { store.enabledApps != nil }

        // What the panel actually displays: the backend's filter AND order,
        // not the catalog's 7 sources.
        let displayed = AudioSourceCatalog.ordered(enabledApps: store.enabledApps).map(\.id)
        #expect(displayed == StubMiloBackend.enabledApps)
        #expect(displayed.count < AudioSourceCatalog.allIds.count)
    }

    // MARK: - Recovery after a completely failed bootstrap

    @Test("Opening the panel recovers a failed bootstrap and realigns the volume limits")
    func openingPanelRecoversFailedBootstrap() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }

        // Always fails: the 3 bootstrap attempts are exhausted.
        backend.bulkFailuresRemaining = .max

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        // State and volume do load, though: that is the situation of the bug.
        try await waitUntil(timeout: 15) { store.volume != nil }
        #expect(store.enabledApps == nil)
        #expect(store.volumeLimits.minDb == VolumeDefaults.limitMinDb, "fallback limits")
        #expect(store.volumeLimits.maxDb == VolumeDefaults.limitMaxDb)

        // The backend recovers; the user opens the panel.
        backend.bulkFailuresRemaining = 0
        store.refreshPanelData()

        try await waitUntil(timeout: 15) { store.enabledApps != nil }
        #expect(store.enabledApps == StubMiloBackend.enabledApps)

        // The limits must be realigned on the VolumeStatus already in memory, otherwise
        // the slider and the HUD would stay bounded to the fallback until the next event.
        #expect(store.volumeLimits.minDb == StubMiloBackend.limitMinDb)
        #expect(store.volumeLimits.maxDb == StubMiloBackend.limitMaxDb)
    }

    @Test("The background poll retries the /bulk while enabledApps is nil",
          .timeLimit(.minutes(2)))
    func backgroundRefreshRetriesBulk() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.bulkFailuresRemaining = .max

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        try await waitUntil(timeout: 15) { store.volume != nil }
        #expect(store.enabledApps == nil)

        // The backend recovers, but nobody opens the panel: only the background poll can
        // catch up. Without the fix it only refreshes the state, and `enabledApps` would
        // stay nil until the next reconnection.
        let hitsBefore = backend.bulkHits
        backend.bulkFailuresRemaining = 0

        try await waitUntil(timeout: Self.backgroundRefreshInterval + 15) {
            store.enabledApps != nil
        }

        #expect(store.enabledApps == StubMiloBackend.enabledApps)
        #expect(backend.bulkHits > hitsBefore)
        #expect(store.volumeLimits.minDb == StubMiloBackend.limitMinDb)
    }

    @Test("A /bulk that succeeds first time is never retried")
    func healthyBootstrapDoesNotRetry() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.bulkFailuresRemaining = 0

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        try await waitUntil(timeout: 15) { store.enabledApps != nil }

        // The nominal path must not be slowed down: a single call, and opening the panel
        // must not trigger another one.
        store.refreshPanelData()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(backend.bulkHits == 1)
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
