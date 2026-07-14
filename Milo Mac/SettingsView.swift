import SwiftUI
import ServiceManagement

// MARK: - ViewModel

@MainActor
@Observable
final class SettingsViewModel {
    // Dependencies
    weak var hotkeyManager: GlobalHotkeyManager?
    weak var rocVADManager: RocVADManager?

    // General
    var launchAtLogin: Bool
    var hotkeysEnabled: Bool
    var volumeDelta: Double
    var showVolumeHUDOnAllChanges: Bool

    // ROC VAD

    var rocVADInstalled: Bool

    /// Dépliage de la section « Audio Mac ». État d'UI pur, volontairement **non
    /// persisté** : la section est repliée à chaque ouverture des Réglages, ses options
    /// étant des réglages d'expert qu'on ne veut pas imposer d'entrée. Ne surtout pas le
    /// remettre dans RocVADSettings — son saveToUserDefaults() écraserait la valeur
    /// courante par celle lue au lancement (le dépliage se perdait au clic sur Appliquer).
    var macAudioExpanded = false

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
            pendingSettings = RocVADPreset.allCases[newValue].toSettings()
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

        self.hotkeysEnabled = hotkeyManager?.isMonitoring ?? false
        self.volumeDelta = hotkeyManager?.volumeDeltaDb ?? 3
        self.showVolumeHUDOnAllChanges = UserDefaults.standard.bool(forKey: DefaultsKey.showVolumeHUDOnAllChanges)

        // Test rapide (présence du binaire) pour ne pas bloquer l'ouverture de
        // la fenêtre — `roc-vad info` passe par gRPC et peut prendre plusieurs
        // secondes ; le vrai statut driver est rafraîchi en arrière-plan.
        self.rocVADInstalled = RocVADManager.isBinaryInstalled
        self.pendingSettings = rocVADManager?.settings ?? RocVADSettings()

        // Le vrai statut du driver, en arrière-plan : `roc-vad info` passe par gRPC.
        if let rocVADManager {
            Task { [weak self] in
                let isWorking = await rocVADManager.checkInstallation()
                self?.rocVADInstalled = isWorking
            }
        }
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
        hotkeyManager?.volumeDeltaDb = volumeDelta
    }

    func toggleShowVolumeHUD() {
        UserDefaults.standard.set(showVolumeHUDOnAllChanges, forKey: DefaultsKey.showVolumeHUDOnAllChanges)
    }

    func apply() {
        guard let rocVADManager else { return }
        isApplying = true

        Task {
            let success = await rocVADManager.updateSettings(pendingSettings)
            isApplying = false
            NSLog(success ? "Settings applied successfully" : "Failed to apply settings")
        }
    }

    func reset() {
        pendingSettings = RocVADSettings()
    }
}

// MARK: - Preset Options (for Picker)

private struct PresetOption: Identifiable, Hashable {
    let id: Int
    let name: String
}

// MARK: - Slider Row

/// Ligne « intitulé + curseur + valeur ».
///
/// Les largeurs sont fixes et partagées par toutes les lignes : `LabeledContent` donne à
/// la partie droite la place que lui laisse l'intitulé, donc un curseur simplement
/// `minWidth`é serait plus ou moins large selon la longueur du texte à sa gauche. Ici tous
/// les curseurs font la même largeur et toutes les valeurs sont alignées à droite, quelle
/// que soit la langue.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let valueText: String

    private static let sliderWidth: CGFloat = 120
    private static let valueWidth: CGFloat = 50

    var body: some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                // Absorbe la place restante pour que le bloc reste collé à droite,
                // aligné avec les autres contrôles du formulaire.
                Spacer(minLength: 0)

                Slider(value: $value, in: range, step: 1)
                    .frame(width: Self.sliderWidth)

                Text(valueText)
                    .monospacedDigit()
                    .frame(width: Self.valueWidth, alignment: .trailing)
            }
        }
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    /// roc-vad n'est plus un péage au lancement : son état vit ici, et la source « Mac »
    /// du panneau reste désactivée tant que le driver n'est pas prêt.
    @Bindable var store: MiloStore

    @State private var installFailed = false

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

                Toggle(L("settings.volume_hud_all_changes"), isOn: $vm.showVolumeHUDOnAllChanges)
                    .onChange(of: vm.showVolumeHUDOnAllChanges) { _, _ in
                        vm.toggleShowVolumeHUD()
                    }

                Toggle(L("settings.hotkeys"), isOn: $vm.hotkeysEnabled)
                    .onChange(of: vm.hotkeysEnabled) { _, _ in
                        vm.toggleHotkeys()
                        vm.onNeedsResize?()
                    }

                if vm.hotkeysEnabled {
                    SliderRow(title: L("settings.volume_increment"),
                              value: $vm.volumeDelta,
                              range: 1...6,
                              valueText: "\(Int(vm.volumeDelta)) dB")
                        .onChange(of: vm.volumeDelta) { _, _ in
                            vm.updateVolumeDelta()
                        }
                }
            }

            // MARK: Mac Audio Section
            if !vm.rocVADInstalled {
                macAudioSetupSection
            } else if store.rocVADNeedsRestart {
                restartRequiredSection
            } else {
                Section(isExpanded: $vm.macAudioExpanded) {
                    // Preset
                    Picker(L("settings.preset"), selection: $vm.selectedPresetIndex) {
                        ForEach(presetOptions) { option in
                            Text(option.name).tag(option.id)
                        }
                    }

                    // Buffer
                    SliderRow(title: L("settings.buffer"),
                              value: $vm.deviceBuffer,
                              range: Double(RocVADSettings.deviceBufferRange.lowerBound)...Double(RocVADSettings.deviceBufferRange.upperBound),
                              valueText: "\(vm.pendingSettings.deviceBuffer) ms")

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
                    SliderRow(title: L("settings.packet_length"),
                              value: $vm.packetLength,
                              range: Double(RocVADSettings.packetLengthRange.lowerBound)...Double(RocVADSettings.packetLengthRange.upperBound),
                              valueText: "\(vm.pendingSettings.packetLength) ms")

                    // FEC Source Packets
                    SliderRow(title: L("settings.fec_source"),
                              value: $vm.fecBlockSource,
                              range: Double(RocVADSettings.fecBlockSourceRange.lowerBound)...Double(RocVADSettings.fecBlockSourceRange.upperBound),
                              valueText: "\(vm.pendingSettings.fecBlockSource)")

                    // FEC Repair Packets
                    SliderRow(title: L("settings.fec_repair"),
                              value: $vm.fecBlockRepair,
                              range: Double(RocVADSettings.fecBlockRepairRange.lowerBound)...Double(RocVADSettings.fecBlockRepairRange.upperBound),
                              valueText: "\(vm.pendingSettings.fecBlockRepair)")

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
                .onChange(of: vm.macAudioExpanded) { _, _ in
                    vm.onNeedsResize?()
                }
                .animation(nil, value: vm.macAudioExpanded)
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        // La fenêtre n'est plus dimensionnée par AppKit (voir SettingsWindowPresenter) : ces
        // deux drapeaux échangent la section « Audio Mac », donc changent la hauteur.
        .onChange(of: vm.rocVADInstalled) { _, _ in vm.onNeedsResize?() }
        .onChange(of: store.rocVADNeedsRestart) { _, _ in vm.onNeedsResize?() }
    }

    // MARK: - roc-vad absent

    /// Milō fonctionne sans roc-vad (toutes les sources sauf « Mac »). L'installation est
    /// donc proposée ici, à la demande — jamais imposée au lancement.
    private var macAudioSetupSection: some View {
        Section(L("settings.mac_audio")) {
            Text(L("settings.rocvad.description"))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if installFailed {
                Label(L("settings.rocvad.install_failed"), systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout)
            }

            HStack {
                Spacer()
                Button(store.isInstallingRocVAD ? L("settings.rocvad.installing") : L("settings.rocvad.install")) {
                    installFailed = false
                    store.installRocVAD { success in
                        installFailed = !success
                        // Le binaire vient d'apparaître : rafraîchir l'état affiché.
                        vm.rocVADInstalled = RocVADManager.isBinaryInstalled
                        vm.onNeedsResize?()
                    }
                }
                .disabled(store.isInstallingRocVAD)
                .keyboardShortcut(.defaultAction)
            }
        }
        .onChange(of: installFailed) { _, _ in vm.onNeedsResize?() }
    }

    /// Le driver n'est chargé qu'après redémarrage. On l'annonce — on ne redémarre pas le
    /// Mac à la place de l'utilisateur : un redémarrage forcé ne laisse pas les autres
    /// applications enregistrer leur travail.
    private var restartRequiredSection: some View {
        Section(L("settings.mac_audio")) {
            Label(L("settings.rocvad.restart_required"), systemImage: "arrow.clockwise.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
