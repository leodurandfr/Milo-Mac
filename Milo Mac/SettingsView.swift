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

    // Callback for window resize (not tracked by Observation)
    @ObservationIgnored
    var onNeedsResize: (() -> Void)?

    /// Watches for the app coming back to the front, to re-read the Accessibility
    /// permission. Not tracked by Observation — it is plumbing, not state.
    @ObservationIgnored
    private var activationObserver: (any NSObjectProtocol)?

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

}

// MARK: - SettingsView

struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    /// roc-vad is no longer a toll at launch: its state lives here, and the panel's "Mac"
    /// source stays disabled as long as the driver is not ready.
    @Bindable var store: MiloStore

    @State private var installFailed = false

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
                macAudioLinkSection
            }
        }
        .formStyle(.grouped)
        .frame(width: 400)
        // The window is no longer sized by AppKit (see SettingsWindowPresenter): these
        // swap or grow the "Mac Audio" section, and therefore change the height.
        .onChange(of: vm.rocVADInstalled) { _, _ in vm.onNeedsResize?() }
        .onChange(of: store.rocVADNeedsRestart) { _, _ in vm.onNeedsResize?() }
        // Milō's link arriving adds its four rows.
        .onChange(of: vm.rocVADManager?.settings) { _, _ in vm.onNeedsResize?() }
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

    // MARK: - roc-vad ready

    /// What the Milō device sends with, read-only: the link is set on Milō, in its "macOS
    /// receiver" settings, where it is measured and where both of its ends are applied from
    /// together. Editing one end here is how the two came to disagree.
    private var macAudioLinkSection: some View {
        Section(L("settings.mac_audio")) {
            if let link = vm.rocVADManager?.settings {
                LabeledContent(L("settings.packet_length"), value: "\(link.packetLength) ms")
                LabeledContent(L("settings.fec_source"), value: "\(link.fecBlockSource)")
                LabeledContent(L("settings.fec_repair"), value: "\(link.fecBlockRepair)")
                Toggle(L("settings.interleaving"), isOn: .constant(link.packetInterleaving))
                    .disabled(true)
                linkNote(L("settings.rocvad.set_from_milo"))
            } else {
                linkNote(L("settings.rocvad.waiting_for_milo"))
            }
        }
    }

    private func linkNote(_ text: String) -> some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
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
