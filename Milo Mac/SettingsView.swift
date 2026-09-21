import AppKit
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

    /// Whether macOS currently lets the shortcuts read the keyboard.
    ///
    /// Mirrored here rather than read straight from the view: the permission is granted in
    /// *another* app, and nothing tells us about it, so a view calling `AXIsProcessTrusted()`
    /// inline would never be asked to re-render. It is refreshed whenever Milō comes back to
    /// the front — which is exactly when someone returns from System Settings.
    var isAccessibilityTrusted: Bool

    // ROC VAD

    var rocVADInstalled: Bool

    /// Expansion of the "Mac Audio" section. Pure UI state, deliberately **not
    /// persisted**: the section is collapsed every time Settings opens, its options being
    /// expert settings we do not want to impose up front. Do not move it back into
    /// RocVADSettings — its saveToUserDefaults() would overwrite the current value with the
    /// one read at launch (the expansion was lost when clicking Apply).
    var macAudioExpanded = false

    var pendingSettings: RocVADSettings
    var isApplying: Bool = false

    // Callback for window resize (not tracked by Observation)
    @ObservationIgnored
    var onNeedsResize: (() -> Void)?

    /// Watches for the app coming back to the front, to re-read the Accessibility
    /// permission. Not tracked by Observation — it is plumbing, not state.
    @ObservationIgnored
    private var activationObserver: (any NSObjectProtocol)?

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

        // The persisted preference, not `isMonitoring`: the shortcuts are only armed while
        // Milō is connected AND the permission is granted, so reading the running state
        // would show this switch off for reasons that have nothing to do with the choice
        // the user made.
        self.hotkeysEnabled = hotkeyManager?.isEnabled ?? true
        self.volumeDelta = hotkeyManager?.volumeDeltaDb ?? 3
        self.isAccessibilityTrusted = GlobalHotkeyManager.isAccessibilityTrusted
        self.showVolumeHUDOnAllChanges = UserDefaults.standard.bool(forKey: DefaultsKey.showVolumeHUDOnAllChanges)

        // A quick test (is the binary there) so the window's opening is not blocked —
        // `roc-vad info` goes through gRPC and can take several seconds; the real driver
        // status is refreshed in the background.
        self.rocVADInstalled = RocVADManager.isBinaryInstalled
        self.pendingSettings = rocVADManager?.settings ?? RocVADSettings()

        // The real driver status, in the background: `roc-vad info` goes through gRPC.
        if let rocVADManager {
            Task { [weak self] in
                let isWorking = await rocVADManager.checkInstallation()
                self?.rocVADInstalled = isWorking
            }
        }

        // `queue: .main`: AppKit posts this on the main thread, which is what the
        // `assumeIsolated` asserts. Only the refresh crosses it, and it returns nothing.
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshAccessibilityTrust() }
        }
    }

    isolated deinit {
        if let activationObserver {
            NotificationCenter.default.removeObserver(activationObserver)
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
        hotkeyManager?.setEnabled(hotkeysEnabled)
        // Switching them on is one of the two moments allowed to post the system alert, so
        // the permission may have been granted a fraction of a second ago.
        refreshAccessibilityTrust()
    }

    func updateVolumeDelta() {
        hotkeyManager?.volumeDeltaDb = volumeDelta
    }

    func toggleShowVolumeHUD() {
        UserDefaults.standard.set(showVolumeHUDOnAllChanges, forKey: DefaultsKey.showVolumeHUDOnAllChanges)
    }

    /// Re-reads the permission, and acts on it.
    ///
    /// Acting matters as much as reading: coming back from System Settings with the box
    /// newly ticked, there may be no permission watch running at all — the system alert is
    /// only posted once per app, and the watch is started by that request. Hiding the
    /// notice without arming would leave ⌥↑/↓ dead until the next relaunch.
    func refreshAccessibilityTrust() {
        let trusted = GlobalHotkeyManager.isAccessibilityTrusted
        guard trusted != isAccessibilityTrusted else { return }
        isAccessibilityTrusted = trusted

        if trusted {
            hotkeyManager?.startMonitoringIfPossible()
        }

        // The notice row appears or disappears: the window has to follow.
        onNeedsResize?()
    }

    /// Opens the Accessibility pane of System Settings.
    ///
    /// This is the only route left once TCC has spent its single alert: from then on
    /// `AXIsProcessTrustedWithOptions` answers `false` without showing anything, so a
    /// button that pretended to ask again would do nothing at all.
    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
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

// MARK: - Metric Slider

/// The four roc-vad sliders differ only by their label, binding, range and unit.
///
/// This forwards straight to the system slider and lays out nothing of its own: the label
/// column, the value readout and the bounds are the form's and the slider's doing. It
/// replaces a hand-rolled row that pinned the slider to 120 pt and the value to 50 pt,
/// because `LabeledContent` gave the trailing part whatever room the label left it — so
/// the sliders came out at different widths depending on the length of the text beside
/// them, and on the language.
///
/// **Continuous, deliberately.** A `step:` makes macOS 26 draw a tick at every stop, and
/// there is no modifier to turn that off — over 2…200 that is 199 dots, which reads as a
/// dotted rule rather than a track. Integrality is not lost: every binding behind these
/// rounds in its setter, and the buffer snaps to fives above 20.
private struct MetricSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Int>
    var unit: String = ""

    var body: some View {
        Slider(
            value: $value,
            in: Double(range.lowerBound)...Double(range.upperBound),
            label: { Text(title) },
            currentValueLabel: { Text(readout(Int(value))) },
            minimumValueLabel: { Text(readout(range.lowerBound)) },
            maximumValueLabel: { Text(readout(range.upperBound)) }
        )
    }

    private func readout(_ amount: Int) -> String {
        unit.isEmpty ? "\(amount)" : "\(amount) \(unit)"
    }
}

// MARK: - SettingsView

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    /// roc-vad is no longer a toll at launch: its state lives here, and the panel's "Mac"
    /// source stays disabled as long as the driver is not ready.
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

                // Two Texts in the label: the form renders the first as the row's title and
                // the second as its secondary line. The whole sentence used to be the title.
                Toggle(isOn: $vm.showVolumeHUDOnAllChanges) {
                    Text(L("settings.volume_hud_all_changes"))
                    Text(L("settings.volume_hud_all_changes.description"))
                }
                .onChange(of: vm.showVolumeHUDOnAllChanges) { _, _ in
                    vm.toggleShowVolumeHUD()
                }

                Toggle(L("settings.hotkeys"), isOn: $vm.hotkeysEnabled)
                    .onChange(of: vm.hotkeysEnabled) { _, _ in
                        vm.toggleHotkeys()
                        vm.onNeedsResize?()
                    }

                if vm.hotkeysEnabled {
                    if !vm.isAccessibilityTrusted {
                        accessibilityNoticeRow
                    }

                    // Six stops, so every one of them gets a tick: the step is a value the
                    // user picks exactly, not a position they aim at.
                    Slider(
                        value: $vm.volumeDelta,
                        in: 1...6,
                        step: 1,
                        label: { Text(L("settings.volume_increment")) },
                        currentValueLabel: { Text("\(Int(vm.volumeDelta)) dB") },
                        minimumValueLabel: { Text("1 dB") },
                        maximumValueLabel: { Text("6 dB") },
                        tick: { SliderTick($0) }
                    )
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
                    MetricSlider(title: L("settings.buffer"),
                                 value: $vm.deviceBuffer,
                                 range: RocVADSettings.deviceBufferRange,
                                 unit: "ms")

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
                    MetricSlider(title: L("settings.packet_length"),
                                 value: $vm.packetLength,
                                 range: RocVADSettings.packetLengthRange,
                                 unit: "ms")

                    // FEC Source Packets
                    MetricSlider(title: L("settings.fec_source"),
                                 value: $vm.fecBlockSource,
                                 range: RocVADSettings.fecBlockSourceRange)

                    // FEC Repair Packets
                    MetricSlider(title: L("settings.fec_repair"),
                                 value: $vm.fecBlockRepair,
                                 range: RocVADSettings.fecBlockRepairRange)

                    // Interleaving
                    Toggle(L("settings.interleaving"), isOn: $vm.pendingSettings.packetInterleaving)

                    // Buttons. Applying recreates the "Milō" device, so it stays an explicit,
                    // batched act rather than firing on every slider notch.
                    HStack {
                        Spacer()

                        if vm.isApplying {
                            ProgressView()
                                .controlSize(.small)
                        }

                        Button(L("settings.reset")) {
                            vm.reset()
                        }
                        .disabled(!vm.hasNonDefaultValues || vm.isApplying)

                        Button(L("settings.apply")) {
                            vm.apply()
                        }
                        .disabled(!vm.hasChanges || vm.isApplying)
                        .keyboardShortcut(.defaultAction)
                    }
                } header: {
                    // The whole header toggles the section, not just the disclosure
                    // triangle.
                    //
                    // `Section(_:isExpanded:)` wires only the triangle — a ~12 pt target at
                    // the far left of a 400 pt window, which reads as a section that does
                    // not open. This is why the header is built by hand rather than passed
                    // as a title: the hit area is the whole point, and there is no modifier
                    // that widens the native one.
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
        // The window is no longer sized by AppKit (see SettingsWindowPresenter): these two
        // flags swap the "Mac Audio" section, and therefore change the height.
        .onChange(of: vm.rocVADInstalled) { _, _ in vm.onNeedsResize?() }
        .onChange(of: store.rocVADNeedsRestart) { _, _ in vm.onNeedsResize?() }
    }

    // MARK: - Accessibility permission

    /// The app's entire insistence about the Accessibility permission.
    ///
    /// The system alert is posted once, when the panel is first opened (`MenuBarShell`),
    /// and TCC never shows it again — so this standing, non-modal row is what remains: it
    /// says why the shortcuts are silent, and points at the one place that can fix it.
    /// Deliberately not a window at every launch: Milō works without the shortcuts.
    private var accessibilityNoticeRow: some View {
        LabeledContent {
            Button(L("settings.accessibility.open")) {
                vm.openAccessibilitySettings()
            }
        } label: {
            Text(L("settings.accessibility.required"))
            Text(L("settings.accessibility.explanation"))
        }
    }

    // MARK: - roc-vad absent

    /// Milō works without roc-vad (every source but "Mac"). Installation is therefore
    /// offered here, on demand — never imposed at launch.
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
                        // The binary has just appeared: refresh the displayed state.
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

    /// The driver only loads after a restart. We announce it — we do not restart the Mac
    /// on the user's behalf: a forced restart does not let other applications save their
    /// work.
    private var restartRequiredSection: some View {
        Section(L("settings.mac_audio")) {
            Label(L("settings.rocvad.restart_required"), systemImage: "arrow.clockwise.circle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
