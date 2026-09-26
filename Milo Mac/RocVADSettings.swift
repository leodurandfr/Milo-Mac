import Foundation

/// The sender half of the Mac → Milō ROC link, as Milō sets it.
///
/// Milō owns the whole link: its receiver (roc-recv) and this sender are configured together
/// from Milō's "macOS receiver" settings, where an analysis measures the link and proposes
/// both halves. This app only applies what arrives — from `/api/settings/bulk` (`mac_roc`)
/// at connect and from `settings/mac_roc_changed` afterwards — to its roc-vad device.
///
/// Two roc-vad options are deliberately not here:
/// - **the FEC scheme**: Milō's receiver listens on `rtp+rs8m`, and roc refuses a sender on
///   any other scheme when the device connects;
/// - **the device buffer**: roc-vad drains it on every CoreAudio I/O cycle, so it adds no
///   latency, and one smaller than CoreAudio's I/O buffer overruns roc-vad's ring. roc-vad's
///   own default is left in place.
struct RocVADSettings: Equatable, Sendable {
    var packetLength: Int
    var fecBlockSource: Int
    var fecBlockRepair: Int
    var packetInterleaving: Bool

    /// Reads the sender half of Milō's `mac_roc` object — the same keys in `/bulk` and in
    /// the `config` of `settings/mac_roc_changed`. Nil when any of them is missing: a link
    /// half-described is not one to rebuild the device for.
    init?(miloLink: [String: Any]) {
        guard let packetLength = miloLink["packet_length_ms"] as? Int,
              let fecBlockSource = miloLink["fec_block_source"] as? Int,
              let fecBlockRepair = miloLink["fec_block_repair"] as? Int,
              let packetInterleaving = miloLink["packet_interleaving"] as? Bool else { return nil }
        self.init(packetLength: packetLength, fecBlockSource: fecBlockSource,
                  fecBlockRepair: fecBlockRepair, packetInterleaving: packetInterleaving)
    }

    init(packetLength: Int, fecBlockSource: Int, fecBlockRepair: Int, packetInterleaving: Bool) {
        self.packetLength = packetLength
        self.fecBlockSource = fecBlockSource
        self.fecBlockRepair = fecBlockRepair
        self.packetInterleaving = packetInterleaving
    }

    /// roc-vad arguments for `device add sender`.
    func toDeviceArguments() -> [String] {
        var args = [
            "--packet-length", "\(packetLength)ms",
            "--fec-encoding", "rs8m",
            "--fec-block-nbsrc", "\(fecBlockSource)",
            "--fec-block-nbrpr", "\(fecBlockRepair)",
        ]
        if packetInterleaving {
            args.append("--packet-interleaving")
        }
        return args
    }
}

/// What `roc-vad device show` says a device runs — enough to tell whether it already is the
/// device Milō asks for, which spares a rebuild (and the output switch it causes).
struct RocVADDeviceDescription: Equatable, Sendable {
    var uid: String?
    var packetLength: Int?
    var packetInterleaving: Bool?
    var fecBlockSource: Int?
    var fecBlockRepair: Int?
    var sourceEndpoint: String?

    init(showOutput output: String) {
        for line in output.components(separatedBy: .newlines) {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2 else { continue }
            let (key, value) = (parts[0], parts[1])
            switch key {
            case "uid": uid = value
            case "packet_length": packetLength = Int(value.replacingOccurrences(of: "ms", with: ""))
            case "packet_interleaving": packetInterleaving = value == "true"
            case "fec_block_nbsrc": fecBlockSource = Int(value)
            case "fec_block_nbrpr": fecBlockRepair = Int(value)
            case "audiosrc": sourceEndpoint = value
            default: continue
            }
        }
    }

    /// The device sends to `host` with exactly these settings.
    func matches(host: String, sourcePort: Int, settings: RocVADSettings) -> Bool {
        sourceEndpoint == "rtp+rs8m://\(host):\(sourcePort)"
            && packetLength == settings.packetLength
            && packetInterleaving == settings.packetInterleaving
            && fecBlockSource == settings.fecBlockSource
            && fecBlockRepair == settings.fecBlockRepair
    }
}
