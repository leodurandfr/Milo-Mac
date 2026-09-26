import Testing
import Foundation
@testable import Milo

/// The sender half of Milō's ROC link, from the wire to roc-vad's arguments.
///
/// What breaks when these fail: the Mac rebuilds its "Milō" device with values Milō never
/// sent, or rebuilds it when nothing changed — and every rebuild takes the sound output
/// away from whoever is listening.
struct MacLinkTests {

    /// Milō's `mac_roc` as `/bulk` serves it and `settings/mac_roc_changed` carries it.
    private static func miloLink() -> [String: Any] {
        ["target_latency_ms": 30, "latency_profile": "gradual", "frame_length_ms": 4,
         "packet_length_ms": 3, "fec_block_source": 10, "fec_block_repair": 5,
         "packet_interleaving": false]
    }

    @Test("Milō's link decodes to its sender half")
    func decodesTheSenderHalf() throws {
        let settings = try #require(RocVADSettings(miloLink: Self.miloLink()))
        #expect(settings == RocVADSettings(packetLength: 3, fecBlockSource: 10,
                                           fecBlockRepair: 5, packetInterleaving: false))
    }

    @Test("A link missing one sender key is not applied")
    func aHalfDescribedLinkIsRefused() {
        var partial = Self.miloLink()
        partial.removeValue(forKey: "fec_block_repair")
        #expect(RocVADSettings(miloLink: partial) == nil)
    }

    @Test("The device always speaks rs8m, and interleaves only when told to")
    func argumentsFollowTheReceiver() {
        let plain = RocVADSettings(packetLength: 3, fecBlockSource: 10, fecBlockRepair: 5, packetInterleaving: false)
        #expect(plain.toDeviceArguments() == ["--packet-length", "3ms", "--fec-encoding", "rs8m",
                                              "--fec-block-nbsrc", "10", "--fec-block-nbrpr", "5"])

        var interleaved = plain
        interleaved.packetInterleaving = true
        #expect(interleaved.toDeviceArguments().last == "--packet-interleaving")
    }

    /// `roc-vad device show 83`, verbatim, on 2026-09-26.
    private static let shown = """
    Device #83

      type:   sender
      uid:    1795d9-02b066-e78b5d-e41cd0
      name:   Milō
      state:  on

      device_encoding:
        rate:      44100Hz
        channels:  stereo
        buffer:    20ms

      sender_config:
        packet_length:        3ms
        packet_interleaving:  true
        packet_encoding:      default

        fec_encoding:     rs8m
        fec_block_nbsrc:  10
        fec_block_nbrpr:  5

        resampler_backend:  default
        resampler_profile:  high

      remote_endpoints:
        slot 0:
          audiosrc:      rtp+rs8m://192.168.1.55:10001
          audiorpr:      rs8m://192.168.1.55:10002
          audioctl:      rtcp://192.168.1.55:10003
    """

    @Test("A device already running Milō's link is left alone")
    func aMatchingDeviceIsNotRebuilt() {
        let description = RocVADDeviceDescription(showOutput: Self.shown)
        #expect(description.uid == "1795d9-02b066-e78b5d-e41cd0")

        let asShown = RocVADSettings(packetLength: 3, fecBlockSource: 10, fecBlockRepair: 5, packetInterleaving: true)
        #expect(description.matches(host: "192.168.1.55", sourcePort: 10001, settings: asShown))
    }

    @Test("A different link, or a different host, rebuilds the device")
    func anyDifferenceRebuilds() {
        let description = RocVADDeviceDescription(showOutput: Self.shown)
        let asShown = RocVADSettings(packetLength: 3, fecBlockSource: 10, fecBlockRepair: 5, packetInterleaving: true)

        var noInterleaving = asShown
        noInterleaving.packetInterleaving = false
        #expect(!description.matches(host: "192.168.1.55", sourcePort: 10001, settings: noInterleaving))
        #expect(!description.matches(host: "192.168.1.39", sourcePort: 10001, settings: asShown))
    }

    @Test("The link arrives with /bulk at connect")
    func bulkCarriesTheLink() async throws {
        let backend = try StubMiloBackend.start()
        defer { backend.stop() }

        let api = MiloAPIService(host: "127.0.0.1", port: backend.port, resolvedIPv4: "127.0.0.1")
        let settings = try await api.fetchBulkSettings()
        #expect(settings.macSender == RocVADSettings(packetLength: 3, fecBlockSource: 10,
                                                      fecBlockRepair: 5, packetInterleaving: false))
    }
}
