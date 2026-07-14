import Testing
import Foundation
// Le module suit PRODUCT_NAME (« Milo »), pas le nom du target (« Milo Mac ») :
// WRAPPER_NAME ne renomme que le bundle (Milō.app).
@testable import Milo

/// Régression du bug : un `/api/settings/bulk` raté à la connexion n'était jamais retenté.
/// `enabledApps` restait nil pour toute la connexion (les 7 sources s'affichaient sans
/// filtre ni ordre backend) et les limites de volume restaient au repli -80/-21.
///
/// Les tests pilotent le vrai `MiloStore` contre un vrai serveur HTTP local
/// (`StubMiloBackend`), en appelant les méthodes de `MiloConnectionManagerDelegate`
/// exactement comme le fait la couche de connexion.
@MainActor
@Suite(.serialized)
struct BulkSettingsBootstrapTests {

    /// Le poll de fond tourne toutes les 30 s ; ce test l'attend réellement.
    private static let backgroundRefreshInterval: TimeInterval = 30

    // MARK: - Amorçage à la connexion

    @Test("Un /bulk qui échoue puis passe est retenté à la connexion")
    func bootstrapRetriesUntilBulkSucceeds() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }

        // Les deux premiers appels échouent : l'ancien code n'en faisait qu'un.
        backend.bulkFailuresRemaining = 2

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        // Attendre AUSSI le volume : les limites en dérivent (`volumeLimits` renvoie le repli
        // tant que `volume` est nil), et il est chargé par un appel distinct du /bulk. N'attendre
        // que `enabledApps` rendait ce test instable — il lisait parfois le repli avant que
        // /api/volume/state ne soit revenu.
        try await waitUntil(timeout: 15) { store.enabledApps != nil && store.volume != nil }

        #expect(store.enabledApps == StubMiloBackend.enabledApps)
        #expect(backend.bulkHits >= 3, "les deux échecs doivent avoir été retentés")
        // Vraies limites quel que soit l'ordre d'arrivée : /bulk d'abord (le cache amorce
        // getVolumeStatus), ou volume d'abord (refreshBulkSettings recale après coup).
        #expect(store.volumeLimits.minDb == StubMiloBackend.limitMinDb)
        #expect(store.volumeLimits.maxDb == StubMiloBackend.limitMaxDb)
    }

    @Test("Les sources sont filtrées et ordonnées par enabled_apps après un /bulk retenté")
    func sourcesAreFilteredAfterRetriedBulk() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.bulkFailuresRemaining = 2

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        try await waitUntil(timeout: 15) { store.enabledApps != nil }

        // Ce que le panneau affiche réellement : le filtre ET l'ordre du backend,
        // pas les 7 sources du catalogue.
        let displayed = AudioSourceCatalog.ordered(enabledApps: store.enabledApps).map(\.id)
        #expect(displayed == StubMiloBackend.enabledApps)
        #expect(displayed.count < AudioSourceCatalog.allIds.count)
    }

    // MARK: - Rattrapage après un amorçage totalement raté

    @Test("Ouvrir le panneau rattrape un amorçage raté et recale les limites de volume")
    func openingPanelRecoversFailedBootstrap() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }

        // Échoue toujours : les 3 tentatives d'amorçage s'épuisent.
        backend.bulkFailuresRemaining = .max

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        // L'état et le volume, eux, se chargent : c'est la situation du bug.
        try await waitUntil(timeout: 15) { store.volume != nil }
        #expect(store.enabledApps == nil)
        #expect(store.volumeLimits.minDb == VolumeDefaults.limitMinDb, "limites de repli")
        #expect(store.volumeLimits.maxDb == VolumeDefaults.limitMaxDb)

        // Le backend se remet ; l'utilisateur ouvre le panneau.
        backend.bulkFailuresRemaining = 0
        store.refreshPanelData()

        try await waitUntil(timeout: 15) { store.enabledApps != nil }
        #expect(store.enabledApps == StubMiloBackend.enabledApps)

        // Les limites doivent être recalées sur le VolumeStatus déjà en mémoire, sinon
        // le slider et le HUD resteraient bornés au repli jusqu'au prochain événement.
        #expect(store.volumeLimits.minDb == StubMiloBackend.limitMinDb)
        #expect(store.volumeLimits.maxDb == StubMiloBackend.limitMaxDb)
    }

    @Test("Le poll de fond retente le /bulk tant que enabledApps est nil",
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

        // Le backend se remet, mais personne n'ouvre le panneau : seul le poll de fond
        // peut rattraper. Sans le correctif, il ne rafraîchit que l'état et `enabledApps`
        // resterait nil jusqu'à la prochaine reconnexion.
        let hitsBefore = backend.bulkHits
        backend.bulkFailuresRemaining = 0

        try await waitUntil(timeout: Self.backgroundRefreshInterval + 15) {
            store.enabledApps != nil
        }

        #expect(store.enabledApps == StubMiloBackend.enabledApps)
        #expect(backend.bulkHits > hitsBefore)
        #expect(store.volumeLimits.minDb == StubMiloBackend.limitMinDb)
    }

    @Test("Un /bulk qui passe du premier coup n'est jamais retenté")
    func healthyBootstrapDoesNotRetry() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.bulkFailuresRemaining = 0

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        try await waitUntil(timeout: 15) { store.enabledApps != nil }

        // Le chemin nominal ne doit pas être ralenti : un seul appel, et l'ouverture du
        // panneau ne doit pas en déclencher un autre.
        store.refreshPanelData()
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(backend.bulkHits == 1)
    }

    // MARK: - Utilitaire

    /// Attend qu'une condition devienne vraie, en laissant tourner la boucle principale.
    private func waitUntil(timeout: TimeInterval,
                           _ condition: () -> Bool,
                           sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline {
                Issue.record("condition non remplie après \(Int(timeout)) s", sourceLocation: sourceLocation)
                return
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
    }
}
