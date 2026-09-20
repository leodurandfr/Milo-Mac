import Testing
import Foundation
@testable import Milo

/// Régression du bug : Milo-Mac ne lisait que le statut HTTP, alors que Milō sert
/// délibérément certains échecs en 200 + `{"status": "error"}`. Deux routes de la surface
/// appelée ici portent cette enveloppe, et aucune n'était lue :
///
/// - `PUT /api/equalizer/target/local/enabled` — un égaliseur refusé par la cible passait
///   pour accepté, et son spinner tournait jusqu'au filet de sécurité de 10 s.
/// - `GET /api/volume/state` — l'échec se présentait comme un `data` absent, donc comme un
///   état VIDE : `loadMultiroomState` écrasait alors les volumes connus avec zéro client,
///   remettant à plat les sliders de la sous-section multiroom.
///
/// Comme `BulkSettingsBootstrapTests`, ces tests pilotent un vrai `MiloStore` contre un vrai
/// serveur HTTP local — c'est la pile URLSession et le parsing réels qui sont exercés, pas
/// une réimplémentation. Le chemin NOMINAL de ces deux routes, lui, a été vérifié contre le
/// Pi (200 + `status: "success"`) ; seul le refus, qui ne se commande pas sur un appareil
/// réel, se teste au stub.
@MainActor
@Suite(.serialized)
struct StatusEnvelopeTests {

    @Test("Un égaliseur refusé en 200 arrête le spinner au lieu de le laisser tourner")
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
        #expect(store.loadingStates["equalizer"] == true, "le spinner part dès le clic")

        // Il doit tomber par le chemin d'erreur — au plancher d'affichage (1,2 s), très en
        // deçà du filet de sécurité de 10 s qui le résolvait avant le correctif. C'est cet
        // écart que la fenêtre de 5 s mesure.
        try await waitUntil(timeout: 5) { store.loadingStates["equalizer"] != true }
        #expect(store.loadingStates["equalizer"] != true)
    }

    @Test("Un /api/volume/state en erreur ne vide pas les volumes multiroom déjà connus")
    func failingVolumeStateKeepsLastKnownMultiroomVolume() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }
        backend.multiroomEnabled = true

        let store = MiloStore()
        defer { store.miloDidDisconnect() }
        store.connectionManager.injectAPIServiceForTesting(host: "127.0.0.1", port: backend.port)
        store.miloDidConnect()

        // Multiroom actif : le store charge de lui-même la structure ET les volumes.
        try await waitUntil(timeout: 15) { !store.multiroomVolume.clients.isEmpty }
        #expect(store.multiroomVolume.clients[StubMiloBackend.clientMac]?.volumeDb
                == StubMiloBackend.clientVolumeDb)

        // Le service volume tombe, puis l'app recharge — ce que fait tout événement de
        // structure, comme l'ouverture de la sous-section.
        let hitsBefore = backend.volumeStateHits
        backend.volumeStateFails = true
        store.loadMultiroomState()

        try await waitUntil(timeout: 10) { backend.volumeStateHits > hitsBefore }
        try await Task.sleep(nanoseconds: 300_000_000)   // laisser l'échec se propager au store

        #expect(store.multiroomVolume.clients[StubMiloBackend.clientMac]?.volumeDb
                == StubMiloBackend.clientVolumeDb,
                "la dernière valeur connue doit survivre à l'échec, pas être écrasée par du vide")
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
