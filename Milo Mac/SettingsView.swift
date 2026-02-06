import SwiftUI
import ServiceManagement

// MARK: - ViewModel

@available(macOS 14.0, *)
@Observable
class SettingsViewModel {
    // Dependencies
    weak var hotkeyManager: GlobalHotkeyManager?
    weak var rocVADManager: RocVADManager?

    // General
    var launchAtLogin: Bool
    var hotkeysEnabled: Bool
    var volumeDelta: Double

    // ROC VAD
    var rocVADInstalled: Bool
    var macAudioExpanded: Bool
    var pendingSettings: RocVADSettings
    var isApplying: Bool = false

    // Callback for window resize (not tracked by Observation)
    @ObservationIgnored
    var onNeedsResize: (() -> Void)?

    // MARK: - Computed Properties

    var hasChanges: Bool {
        guard let current = rocVADManager?.settings else { return false }
        return pendingSettings != current
    }

    var hasNonDefaultValues: Bool {
        pendingSettings.hasNonDefaultValues
    }

    var selectedPresetIndex: Int {
        get {
            if let preset = RocVADPreset.matchingPreset(for: pendingSettings),
               let index = RocVADPreset.allCases.firstIndex(of: preset) {
                return index
            }
            return RocVADPreset.allCases.count // "Custom"
        }
        set {
            guard newValue < RocVADPreset.allCases.count else { return }
            let preset = RocVADPreset.allCases[newValue]
            let showAdvanced = pendingSettings.showAdvancedOptions
            pendingSettings = preset.toSettings()
            pendingSettings.showAdvancedOptions = showAdvanced
        }
    }

    // MARK: - Double Bindings for Sliders

    var deviceBuffer: Double {
        get { Double(pendingSettings.deviceBuffer) }
        set {
            let snapped: Double
            if newValue <= 20 {
                snapped = newValue.rounded()
            } else {
                snapped = (newValue / 5).rounded() * 5
            }
            pendingSettings.deviceBuffer = Int(snapped)
        }
    }

    var packetLength: Double {
        get { Double(pendingSettings.packetLength) }
        set { pendingSettings.packetLength = Int(newValue.rounded()) }
    }

    var fecBlockSource: Double {
        get { Double(pendingSettings.fecBlockSource) }
        set { pendingSettings.fecBlockSource = Int(newValue.rounded()) }
    }

    var fecBlockRepair: Double {
        get { Double(pendingSettings.fecBlockRepair) }
        set { pendingSettings.fecBlockRepair = Int(newValue.rounded()) }
    }

    // MARK: - Initialization

    init(hotkeyManager: GlobalHotkeyManager?, rocVADManager: RocVADManager?) {
        self.hotkeyManager = hotkeyManager
        self.rocVADManager = rocVADManager

        self.launchAtLogin = SMAppService.mainApp.status == .enabled

        self.hotkeysEnabled = hotkeyManager?.isCurrentlyMonitoring() ?? false
        self.volumeDelta = hotkeyManager?.getVolumeDeltaDb() ?? 3

        self.rocVADInstalled = rocVADManager?.checkInstallation() ?? false
        self.macAudioExpanded = UserDefaults.standard.object(forKey: "RocVAD.ShowAdvancedOptions") as? Bool ?? false
        self.pendingSettings = rocVADManager?.settings ?? RocVADSettings()
    }

    // MARK: - Actions

    func toggleLaunchAtLogin() {
        let service = SMAppService.mainApp
        do {
            if launchAtLogin {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            NSLog("Error toggling launch at login: \(error)")
            launchAtLogin.toggle() // revert
        }
    }

    func toggleHotkeys() {
        guard let hotkeyManager else { return }
        if hotkeysEnabled {
            hotkeyManager.startMonitoring()
        } else {
            hotkeyManager.stopMonitoring()
        }
    }

    func updateVolumeDelta() {
        hotkeyManager?.setVolumeDeltaDb(volumeDelta)
    }

    func apply() {
        guard let rocVADManager else { return }
        isApplying = true

        rocVADManager.updateSettings(pendingSettings) { [weak self] success in
            DispatchQueue.main.async {
                guard let self else { return }
                self.isApplying = false
                if success {
                    NSLog("Settings applied successfully")
                } else {
                    NSLog("Failed to apply settings")
                }
            }
        }
    }

    func reset() {
        let showAdvanced = pendingSettings.showAdvancedOptions
        pendingSettings = RocVADSettings()
        pendingSettings.showAdvancedOptions = showAdvanced
    }
}

// MARK: - Preset Options (for Picker)

private struct PresetOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

// MARK: - SettingsView

@available(macOS 14.0, *)
struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    private var presetOptions: [PresetOption] {
        var options = RocVADPreset.allCases.enumerated().map { PresetOption(id: $0.offset, name: $0.element.displayName) }
        options.append(PresetOption(id: RocVADPreset.allCases.count, name: L("config.rocvad.preset.custom")))
        return options
    }

    var body: some View {
        Form {
            // MARK: General Section
            Section(L("settings.general")) {
                Toggle(L("settings.launch_at_login"), isOn: $vm.launchAtLogin)
                    .onChange(of: vm.launchAtLogin) { _, _ in
                        vm.toggleLaunchAtLogin()
                    }

                Toggle(L("settings.hotkeys"), isOn: $vm.hotkeysEnabled)
                    .onChange(of: vm.hotkeysEnabled) { _, _ in
                        vm.toggleHotkeys()
                        vm.onNeedsResize?()
                    }

                if vm.hotkeysEnabled {
                    LabeledContent(L("settings.volume_increment")) {
                        HStack(spacing: 8) {
                            Slider(value: $vm.volumeDelta, in: 1...6, step: 1)
                                .frame(minWidth: 100)
                            Text("\(Int(vm.volumeDelta)) dB")
                                .monospacedDigit()
                                .frame(width: 36, alignment: .trailing)
                        }
                    }
                    .onChange(of: vm.volumeDelta) { _, _ in
                        vm.updateVolumeDelta()
                    }
                }
            }

            // MARK: Mac Audio Section
            if vm.rocVADInstalled {
                Section(isExpanded: $vm.macAudioExpanded) {
                    // Preset
                    Picker(L("settings.preset"), selection: $vm.selectedPresetIndex) {
                        ForEach(presetOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }

                    // Buffer
                    LabeledContent(L("settings.buffer")) {
                        HStack(spacing: 8) {
                            Slider(value: $vm.deviceBuffer,
                                   in: Double(RocVADSettings.deviceBufferRange.lowerBound)...Double(RocVADSettings.deviceBufferRange.upperBound),
                                   step: 1)
                                .frame(minWidth: 100)
                            Text("\(vm.pendingSettings.deviceBuffer) ms")
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    // Error Correction
                    Picker(L("settings.fec"), selection: $vm.pendingSettings.fecEncoding) {
                        ForEach(FECEncoding.allCases, id: \.self) { encoding in
                            Text(encoding.displayName).tag(encoding)
                        }
                    }

                    // Quality
                    Picker(L("settings.quality"), selection: $vm.pendingSettings.resamplerProfile) {
                        ForEach(ResamplerProfile.allCases, id: \.self) { profile in
                            Text(profile.displayName).tag(profile)
                        }
                    }

                    // Packet Length
                    LabeledContent(L("settings.packet_length")) {
                        HStack(spacing: 8) {
                            Slider(value: $vm.packetLength,
                                   in: Double(RocVADSettings.packetLengthRange.lowerBound)...Double(RocVADSettings.packetLengthRange.upperBound),
                                   step: 1)
                                .frame(minWidth: 100)
                            Text("\(vm.pendingSettings.packetLength) ms")
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    // FEC Source Packets
                    LabeledContent(L("settings.fec_source")) {
                        HStack(spacing: 8) {
                            Slider(value: $vm.fecBlockSource,
                                   in: Double(RocVADSettings.fecBlockSourceRange.lowerBound)...Double(RocVADSettings.fecBlockSourceRange.upperBound),
                                   step: 1)
                                .frame(minWidth: 100)
                            Text("\(vm.pendingSettings.fecBlockSource)")
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    // FEC Repair Packets
                    LabeledContent(L("settings.fec_repair")) {
                        HStack(spacing: 8) {
                            Slider(value: $vm.fecBlockRepair,
                                   in: Double(RocVADSettings.fecBlockRepairRange.lowerBound)...Double(RocVADSettings.fecBlockRepairRange.upperBound),
                                   step: 1)
                                .frame(minWidth: 100)
                            Text("\(vm.pendingSettings.fecBlockRepair)")
                                .monospacedDigit()
                                .frame(width: 50, alignment: .trailing)
                        }
                    }

                    // Interleaving
                    Toggle(L("settings.interleaving"), isOn: $vm.pendingSettings.packetInterleaving)

                    // Buttons
                    HStack {
                        Spacer()
                        Button(L("settings.reset")) {
                            vm.reset()
                        }
                        .disabled(!vm.hasNonDefaultValues || vm.isApplying)

                        Button(L("settings.apply")) {
                            vm.apply()
                        }
                        .disabled(!vm.hasChanges || vm.isApplying)
                        .keyboardShortcut(.defaultAction)
                        .overlay {
                            if vm.isApplying {
                                ProgressView()
                                    .controlSize(.small)
                                    .offset(x: -40)
                            }
                        }
                    }
                } header: {
                    Text(L("settings.mac_audio"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            vm.macAudioExpanded.toggle()
                        }
                }
                .onChange(of: vm.macAudioExpanded) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "RocVAD.ShowAdvancedOptions")
                    vm.onNeedsResize?()
                }
                .animation(nil, value: vm.macAudioExpanded)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
    }
}
