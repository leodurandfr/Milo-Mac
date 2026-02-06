import Foundation

// MARK: - Preset Enum

/// Predefined audio streaming presets for common use cases
enum RocVADPreset: String, CaseIterable {
    case ultraLowLatency = "ultra_low"
    case lowLatency = "low"
    case balanced = "balanced"
    case highQuality = "high_quality"

    var displayName: String {
        switch self {
        case .ultraLowLatency: return L("config.rocvad.preset.ultra_low")
        case .lowLatency: return L("config.rocvad.preset.low")
        case .balanced: return L("config.rocvad.preset.balanced")
        case .highQuality: return L("config.rocvad.preset.high_quality")
        }
    }

    func toSettings() -> RocVADSettings {
        switch self {
        case .ultraLowLatency:
            return RocVADSettings(
                deviceBuffer: 5,
                fecEncoding: .disable,
                resamplerProfile: .low,
                packetLength: 2,
                fecBlockSource: RocVADSettings.defaultFECBlockSource,
                fecBlockRepair: RocVADSettings.defaultFECBlockRepair,
                packetInterleaving: false
            )
        case .lowLatency:
            return RocVADSettings(
                deviceBuffer: 20,
                fecEncoding: .rs8m,
                resamplerProfile: .medium,
                packetLength: 3,
                fecBlockSource: 10,
                fecBlockRepair: 5,
                packetInterleaving: false
            )
        case .balanced:
            return RocVADSettings(
                deviceBuffer: 60,
                fecEncoding: .rs8m,
                resamplerProfile: .medium,
                packetLength: 5,
                fecBlockSource: 18,
                fecBlockRepair: 10,
                packetInterleaving: false
            )
        case .highQuality:
            return RocVADSettings(
                deviceBuffer: 120,
                fecEncoding: .rs8m,
                resamplerProfile: .high,
                packetLength: 7,
                fecBlockSource: 25,
                fecBlockRepair: 15,
                packetInterleaving: true
            )
        }
    }

    /// Find which preset matches the given settings, or nil if custom
    static func matchingPreset(for settings: RocVADSettings) -> RocVADPreset? {
        for preset in allCases {
            let presetSettings = preset.toSettings()
            if presetSettings.deviceBuffer == settings.deviceBuffer &&
               presetSettings.fecEncoding == settings.fecEncoding &&
               presetSettings.resamplerProfile == settings.resamplerProfile &&
               presetSettings.packetLength == settings.packetLength &&
               presetSettings.fecBlockSource == settings.fecBlockSource &&
               presetSettings.fecBlockRepair == settings.fecBlockRepair &&
               presetSettings.packetInterleaving == settings.packetInterleaving {
                return preset
            }
        }
        return nil
    }
}

// MARK: - Enums

/// FEC (Forward Error Correction) encoding types
enum FECEncoding: String, CaseIterable {
    case rs8m = "rs8m"      // Reed-Solomon 8M (standard)
    case ldpc = "ldpc"      // LDPC (high redundancy)
    case disable = "disable" // No FEC

    var displayName: String {
        switch self {
        case .rs8m: return L("config.rocvad.fec.rs8m")
        case .ldpc: return L("config.rocvad.fec.ldpc")
        case .disable: return L("config.rocvad.fec.disable")
        }
    }
}

/// Resampler quality profiles
enum ResamplerProfile: String, CaseIterable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    var displayName: String {
        switch self {
        case .low: return L("config.rocvad.resampler.low")
        case .medium: return L("config.rocvad.resampler.medium")
        case .high: return L("config.rocvad.resampler.high")
        }
    }
}

// MARK: - Settings Struct

/// Configuration settings for ROC VAD sender
struct RocVADSettings {

    // MARK: - Main Options

    /// Device buffer in milliseconds (default: 60ms, range: 2-200ms)
    /// Higher values = more stability, lower values = less latency
    var deviceBuffer: Int

    /// FEC encoding type (default: rs8m)
    var fecEncoding: FECEncoding

    /// Resampler quality profile (default: medium)
    var resamplerProfile: ResamplerProfile

    // MARK: - Advanced Options

    /// Packet length in milliseconds (default: 5ms, range: 2-20ms)
    var packetLength: Int

    /// FEC block source packets (default: 18, range: 10-50)
    var fecBlockSource: Int

    /// FEC block repair packets (default: 10, range: 5-30)
    var fecBlockRepair: Int

    /// Enable packet interleaving for burst loss protection (default: false)
    var packetInterleaving: Bool

    // MARK: - UI State

    /// Whether to show advanced options in the UI
    var showAdvancedOptions: Bool

    // MARK: - Default Values

    static let defaultDeviceBuffer = 60
    static let defaultFECEncoding = FECEncoding.rs8m
    static let defaultResamplerProfile = ResamplerProfile.medium
    static let defaultPacketLength = 5
    static let defaultFECBlockSource = 18
    static let defaultFECBlockRepair = 10
    static let defaultPacketInterleaving = false
    static let defaultShowAdvancedOptions = false

    // MARK: - Ranges

    static let deviceBufferRange = 2...200
    static let packetLengthRange = 2...20
    static let fecBlockSourceRange = 10...50
    static let fecBlockRepairRange = 5...30

    // MARK: - Initialization

    init(
        deviceBuffer: Int = defaultDeviceBuffer,
        fecEncoding: FECEncoding = defaultFECEncoding,
        resamplerProfile: ResamplerProfile = defaultResamplerProfile,
        packetLength: Int = defaultPacketLength,
        fecBlockSource: Int = defaultFECBlockSource,
        fecBlockRepair: Int = defaultFECBlockRepair,
        packetInterleaving: Bool = defaultPacketInterleaving,
        showAdvancedOptions: Bool = defaultShowAdvancedOptions
    ) {
        self.deviceBuffer = deviceBuffer
        self.fecEncoding = fecEncoding
        self.resamplerProfile = resamplerProfile
        self.packetLength = packetLength
        self.fecBlockSource = fecBlockSource
        self.fecBlockRepair = fecBlockRepair
        self.packetInterleaving = packetInterleaving
        self.showAdvancedOptions = showAdvancedOptions
    }

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let deviceBuffer = "RocVAD.DeviceBuffer"
        static let fecEncoding = "RocVAD.FECEncoding"
        static let resamplerProfile = "RocVAD.ResamplerProfile"
        static let packetLength = "RocVAD.PacketLength"
        static let fecBlockSource = "RocVAD.FECBlockSource"
        static let fecBlockRepair = "RocVAD.FECBlockRepair"
        static let packetInterleaving = "RocVAD.PacketInterleaving"
        static let showAdvancedOptions = "RocVAD.ShowAdvancedOptions"
    }

    // MARK: - Persistence

    /// Load settings from UserDefaults
    static func loadFromUserDefaults() -> RocVADSettings {
        let defaults = UserDefaults.standard

        return RocVADSettings(
            deviceBuffer: defaults.object(forKey: Keys.deviceBuffer) as? Int ?? defaultDeviceBuffer,
            fecEncoding: FECEncoding(rawValue: defaults.string(forKey: Keys.fecEncoding) ?? "") ?? defaultFECEncoding,
            resamplerProfile: ResamplerProfile(rawValue: defaults.string(forKey: Keys.resamplerProfile) ?? "") ?? defaultResamplerProfile,
            packetLength: defaults.object(forKey: Keys.packetLength) as? Int ?? defaultPacketLength,
            fecBlockSource: defaults.object(forKey: Keys.fecBlockSource) as? Int ?? defaultFECBlockSource,
            fecBlockRepair: defaults.object(forKey: Keys.fecBlockRepair) as? Int ?? defaultFECBlockRepair,
            packetInterleaving: defaults.object(forKey: Keys.packetInterleaving) as? Bool ?? defaultPacketInterleaving,
            showAdvancedOptions: defaults.object(forKey: Keys.showAdvancedOptions) as? Bool ?? defaultShowAdvancedOptions
        )
    }

    /// Save settings to UserDefaults
    func saveToUserDefaults() {
        let defaults = UserDefaults.standard

        defaults.set(deviceBuffer, forKey: Keys.deviceBuffer)
        defaults.set(fecEncoding.rawValue, forKey: Keys.fecEncoding)
        defaults.set(resamplerProfile.rawValue, forKey: Keys.resamplerProfile)
        defaults.set(packetLength, forKey: Keys.packetLength)
        defaults.set(fecBlockSource, forKey: Keys.fecBlockSource)
        defaults.set(fecBlockRepair, forKey: Keys.fecBlockRepair)
        defaults.set(packetInterleaving, forKey: Keys.packetInterleaving)
        defaults.set(showAdvancedOptions, forKey: Keys.showAdvancedOptions)
    }

    // MARK: - Command Line Arguments

    /// Generate roc-vad command line arguments for device creation
    func toDeviceArguments() -> [String] {
        var args: [String] = []

        // Device buffer
        args.append(contentsOf: ["--device-buffer", "\(deviceBuffer)ms"])

        // Resampler profile
        args.append(contentsOf: ["--resampler-profile", resamplerProfile.rawValue])

        // Packet length
        args.append(contentsOf: ["--packet-length", "\(packetLength)ms"])

        // FEC encoding (only if not disabled)
        if fecEncoding != .disable {
            args.append(contentsOf: ["--fec-encoding", fecEncoding.rawValue])
            args.append(contentsOf: ["--fec-block-nbsrc", "\(fecBlockSource)"])
            args.append(contentsOf: ["--fec-block-nbrpr", "\(fecBlockRepair)"])
        }

        // Packet interleaving
        if packetInterleaving {
            args.append("--packet-interleaving")
        }

        return args
    }

    // MARK: - Comparison

    /// Check if settings differ from defaults
    var hasNonDefaultValues: Bool {
        return deviceBuffer != Self.defaultDeviceBuffer ||
               fecEncoding != Self.defaultFECEncoding ||
               resamplerProfile != Self.defaultResamplerProfile ||
               packetLength != Self.defaultPacketLength ||
               fecBlockSource != Self.defaultFECBlockSource ||
               fecBlockRepair != Self.defaultFECBlockRepair ||
               packetInterleaving != Self.defaultPacketInterleaving
    }

    /// Reset to default values
    mutating func resetToDefaults() {
        deviceBuffer = Self.defaultDeviceBuffer
        fecEncoding = Self.defaultFECEncoding
        resamplerProfile = Self.defaultResamplerProfile
        packetLength = Self.defaultPacketLength
        fecBlockSource = Self.defaultFECBlockSource
        fecBlockRepair = Self.defaultFECBlockRepair
        packetInterleaving = Self.defaultPacketInterleaving
    }
}

// MARK: - Equatable

extension RocVADSettings: Equatable {
    static func == (lhs: RocVADSettings, rhs: RocVADSettings) -> Bool {
        return lhs.deviceBuffer == rhs.deviceBuffer &&
               lhs.fecEncoding == rhs.fecEncoding &&
               lhs.resamplerProfile == rhs.resamplerProfile &&
               lhs.packetLength == rhs.packetLength &&
               lhs.fecBlockSource == rhs.fecBlockSource &&
               lhs.fecBlockRepair == rhs.fecBlockRepair &&
               lhs.packetInterleaving == rhs.packetInterleaving
    }
}
