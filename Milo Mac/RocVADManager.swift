import Foundation
import AppKit

// MARK: - Progress

/// What the driver layer asks to display during an operation. The panel itself is drawn
/// by `RocVADManager`, on the main thread.
enum RocVADProgress: Sendable {
    case show(String)
    case update(String)
    case hide
}

// MARK: - Driver

/// Calls to the roc-vad binary, **serialized**.
///
/// The serialization is not a comfort detail: every operation lists, deletes, recreates and
/// then configures the "Milō" device. Two of them interleaving leave duplicates or a
/// half-configured device. It used to be carried by a serial `DispatchQueue` and by the
/// callers' discipline; it is now carried by the compiler.
///
/// This actor's executor **is** that same serial queue (`DispatchSerialQueue` conforms to
/// `SerialExecutor`). That is not an affectation: the roc-vad calls are synchronous and
/// blocking (`Process.waitUntilExit`, several seconds when the driver answers badly). On
/// the default executor they would block a thread of Swift's cooperative pool, whose width
/// is bounded by the core count. Here they block a queue thread — exactly as before.
///
/// ⚠️ No method on this actor may contain an `await`: a suspension point would reopen
/// reentrancy, hence the interleaving the serial queue forbade. That is why progress is
/// **posted without being awaited** — just as the original `DispatchQueue.main.async` did.
actor RocVADDevice {
    private let queue = DispatchSerialQueue(label: "com.milo.rocvad.device")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let deviceName = "Milō"
    private let sourcePort = 10001
    private let repairPort = 10002
    private let controlPort = 10003

    private var miloHost = "milo.local"
    private var settings: RocVADSettings

    init(settings: RocVADSettings) {
        self.settings = settings
    }

    // MARK: - roc-vad subprocess

    /// Runs roc-vad and waits for it to finish. Synchronous and blocking — hence the
    /// executor above. Returns nil if the binary could not be launched (uninstalled
    /// mid-session, for instance) — unlike launch(), run() is recoverable.
    private nonisolated static func runRocVAD(_ arguments: [String]) -> (status: Int32, output: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: RocVADManager.binaryPath)
        task.arguments = arguments

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            NSLog("❌ roc-vad launch failed: %@", String(describing: error))
            return nil
        }

        // Read before waitUntilExit so we do not block if the output fills the pipe.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Interface

    /// The binary is present AND the driver answers. `roc-vad info` goes through gRPC and
    /// can take several seconds when the driver is half-loaded.
    func isFunctional() -> Bool {
        let working = RocVADManager.isBinaryInstalled && Self.runRocVAD(["info"])?.status == 0
        NSLog(working ? "✅ roc-vad is functional" : "⚠️ roc-vad missing or driver not loaded")
        return working
    }

    /// Installs roc-vad via osascript (which shows the administrator authorization dialog
    /// itself). Blocking: auth + curl + install.
    ///
    /// In a subprocess, rather than through a synchronous `NSAppleScript` on the main
    /// thread — that one froze the progress panel for the whole installation.
    func runInstaller() -> Bool {
        NSLog("📦 Installing roc-vad...")

        let script = """
        do shell script "sudo /bin/bash -c \\"$(curl -fsSL https://raw.githubusercontent.com/roc-streaming/roc-vad/HEAD/install.sh)\\"" with administrator privileges
        """

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = ["-e", script]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        do {
            try task.run()
        } catch {
            NSLog("❌ Failed to launch installer: %@", String(describing: error))
            return false
        }
        task.waitUntilExit()
        return true
    }

    /// Checks the device and only (re)creates it when needed — the common case (device
    /// already fine) shows no panel at all.
    func configureIfNeeded(progress: @Sendable (RocVADProgress) -> Void) -> Bool {
        NSLog("🔧 Checking Milō audio device configuration...")

        let existing = deviceInfo().filter { $0.name == deviceName }

        // Duplicates: delete everything and start over cleanly.
        if existing.count > 1 {
            NSLog("⚠️ Found %d Milō devices - cleaning up duplicates", existing.count)
            deleteAllMiloDevices()
        } else if let device = existing.first {
            NSLog("✅ Found existing Milō device (index: %d)", device.index)

            if isDeviceConfigured(deviceIndex: device.index) {
                NSLog("✅ Device already properly configured - no UI needed")
                return true
            }

            NSLog("🔧 Device needs reconfiguration - showing progress")
            progress(.show(L("progress.reconfiguring_device")))
            defer { progress(.hide) }
            return configureDevice(deviceIndex: device.index)
        }

        NSLog("❌ No Milō device found - showing progress and creating new one")
        progress(.show(L("progress.creating_device")))
        defer { progress(.hide) }

        let index = createMiloDevice()
        guard index > 0 else {
            NSLog("❌ Failed to create Milō device")
            return false
        }

        NSLog("✅ Created new Milō device with index: %d", index)
        return configureDevice(deviceIndex: index)
    }

    /// Repoints the device at the resolved IP. roc-vad does not allow an existing device's
    /// endpoints to be modified: it has to be deleted and recreated.
    func updateHost(_ newHost: String) {
        guard newHost != miloHost else {
            NSLog("🔄 roc-vad: Host unchanged (%@)", newHost)
            return
        }

        NSLog("🔄 Updating roc-vad endpoint from %@ to %@", miloHost, newHost)
        miloHost = newHost

        deleteAllMiloDevices()

        let index = createMiloDevice()
        guard index > 0 else {
            NSLog("❌ Failed to create new Milō device")
            return
        }

        NSLog("🔧 Configuring new device #%d with IP: %@", index, newHost)
        let success = configureDevice(deviceIndex: index)
        NSLog(success ? "✅ Device reconfigured with IP: %@" : "❌ Failed to configure device with IP: %@", newHost)
    }

    /// Applies new settings: the device is recreated with the new arguments.
    func apply(_ newSettings: RocVADSettings, progress: @Sendable (RocVADProgress) -> Void) -> Bool {
        settings = newSettings

        if deleteAllMiloDevices() > 0 {
            // A short delay to make sure the devices really are deleted.
            Thread.sleep(forTimeInterval: 0.5)
        }

        progress(.update(L("progress.creating_device")))

        let index = createMiloDevice()
        guard index > 0 else {
            NSLog("❌ Failed to create new device with updated settings")
            return false
        }
        NSLog("✅ Created new device #%d with updated settings", index)

        progress(.update(L("progress.reconfiguring_device")))

        let success = configureDevice(deviceIndex: index)
        NSLog(success ? "✅ Device reconfigured with new settings" : "❌ Failed to configure device endpoints")
        return success
    }

    // MARK: - roc-vad primitives

    /// Deletes every "Milō" device and returns how many were deleted.
    @discardableResult
    private func deleteAllMiloDevices() -> Int {
        let existing = deviceInfo().filter { $0.name == deviceName }
        for device in existing {
            NSLog("🗑️ Deleting device #%d", device.index)
            let deleted = Self.runRocVAD(["device", "del", "\(device.index)"])?.status == 0
            NSLog(deleted ? "✅ Device #%d deleted" : "⚠️ Failed to delete device #%d", device.index)
        }
        return existing.count
    }

    private func createMiloDevice() -> Int {
        var arguments = ["device", "add", "sender", "--name", deviceName]
        arguments.append(contentsOf: settings.toDeviceArguments())

        NSLog("🔧 Creating device with arguments: %@", arguments.joined(separator: " "))

        guard let result = Self.runRocVAD(arguments) else { return 0 }
        return parseDeviceIndex(from: result.output)
    }

    private func configureDevice(deviceIndex: Int) -> Bool {
        let result = Self.runRocVAD([
            "device", "connect", "\(deviceIndex)",
            "--source", "rtp+rs8m://\(miloHost):\(sourcePort)",
            "--repair", "rs8m://\(miloHost):\(repairPort)",
            "--control", "rtcp://\(miloHost):\(controlPort)"
        ])

        let success = result?.status == 0
        NSLog(success ? "✅ Device configured successfully" : "❌ Device configuration failed")
        return success
    }

    /// Does the device already have its endpoints? We look for the characteristic ROC
    /// ports, without assuming the host (the resolved IP may differ from `miloHost`).
    private func isDeviceConfigured(deviceIndex: Int) -> Bool {
        guard let result = Self.runRocVAD(["device", "show", "\(deviceIndex)"]) else { return false }

        let output = result.output
        return output.contains(":\(sourcePort)")
            && output.contains(":\(repairPort)")
            && output.contains(":\(controlPort)")
    }

    private func deviceInfo() -> [RocVADDeviceInfo] {
        guard let result = Self.runRocVAD(["device", "list"]) else { return [] }
        return parseDeviceList(from: result.output)
    }
}

// MARK: - Manager

/// The roc-vad driver's façade: the UI-side state (settings, progress panel) and the
/// entry point to the driver layer.
///
/// roc-vad is a **state**, never a toll at startup: the app runs perfectly well without it
/// — only the "Mac" source depends on it, and it simply shows up as disabled.
@MainActor
final class RocVADManager {

    /// `nonisolated`: a plain constant, read from the driver layer (off the main actor) as
    /// well as from the UI.
    nonisolated static let binaryPath = "/usr/local/bin/roc-vad"

    /// The binary is present on disk (this says nothing about whether the driver is
    /// loaded — for that, see `checkInstallation()`).
    nonisolated static var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }

    /// A main-isolated copy of the settings, read by SettingsViewModel. The driver layer
    /// keeps its own (it needs it to build the arguments, on its own queue).
    private(set) var settings: RocVADSettings

    private let device: RocVADDevice

    // Progress panel (native NSAlert styling)
    private var progressPanel: NSWindow?
    private var progressLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?

    init() {
        let settings = RocVADSettings.loadFromUserDefaults()
        self.settings = settings
        self.device = RocVADDevice(settings: settings)
        NSLog("📦 RocVADManager initialized with settings: buffer=%dms, fec=%@, resampler=%@",
              settings.deviceBuffer, settings.fecEncoding.rawValue, settings.resamplerProfile.rawValue)
    }

    // MARK: - Interface

    func checkInstallation() async -> Bool {
        await device.isFunctional()
    }

    /// Checks the device and only (re)creates it when needed. The progress panel only
    /// appears if there is work to do.
    @discardableResult
    func configureDeviceOnly() async -> Bool {
        await device.configureIfNeeded(progress: progressSink())
    }

    /// Repoints roc-vad at the resolved IP. Without waiting: the caller (the connection
    /// manager) has nothing to do with the result.
    nonisolated func updateMiloHost(_ newHost: String) {
        Task { await device.updateHost(newHost) }
    }

    func performInstallation() async -> Bool {
        NSLog("🔧 Starting roc-vad installation...")

        showProgressPanel(message: L("progress.preparing"))
        defer { hideProgressPanel() }

        updateProgressMessage(L("progress.downloading"))
        guard await device.runInstaller() else { return false }

        // Let the installation settle, then check. `Task.sleep` and not `Thread.sleep`:
        // we are on the main actor, and the panel has to stay animated.
        try? await Task.sleep(for: .seconds(3))

        updateProgressMessage(L("progress.verifying"))
        try? await Task.sleep(for: .seconds(1))

        guard Self.isBinaryInstalled else {
            NSLog("❌ roc-vad installation failed")
            return false
        }

        updateProgressMessage(L("progress.installation_complete"))
        try? await Task.sleep(for: .seconds(1))
        NSLog("✅ roc-vad installation completed")
        return true
    }

    /// Applies new settings and recreates the device.
    func updateSettings(_ newSettings: RocVADSettings) async -> Bool {
        NSLog("🔧 Updating ROC VAD settings...")

        // Set the main-isolated copy BEFORE the work: that is what SettingsViewModel reads
        // (`hasChanges`), and it has to reflect what is being applied from the moment Apply
        // is clicked.
        settings = newSettings
        newSettings.saveToUserDefaults()
        NSLog("💾 Settings saved: buffer=%dms, fec=%@, resampler=%@",
              newSettings.deviceBuffer, newSettings.fecEncoding.rawValue, newSettings.resamplerProfile.rawValue)

        showProgressPanel(message: L("progress.applying_settings"))
        defer { hideProgressPanel() }

        return await device.apply(newSettings, progress: progressSink())
    }

    // MARK: - Progress panel

    /// The driver layer posts its steps **without awaiting them**: an `await` towards the
    /// main actor from the actor would suspend it, and reopen the interleaving its serial
    /// queue forbids. That is exactly what the original `DispatchQueue.main.async` did.
    private nonisolated func progressSink() -> @Sendable (RocVADProgress) -> Void {
        { [weak self] step in
            Task { @MainActor in self?.applyProgress(step) }
        }
    }

    private func applyProgress(_ step: RocVADProgress) {
        switch step {
        case .show(let message):   showProgressPanel(message: message)
        case .update(let message): updateProgressMessage(message)
        case .hide:                hideProgressPanel()
        }
    }

    // A title-bar-less window, in the NSAlert material.
    private func showProgressPanel(message: String) {
        // One operation can chain into another (updateSettings opens the panel, then the
        // driver layer asks for .show): do not stack two windows.
        guard progressPanel == nil else {
            updateProgressMessage(message)
            return
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 260, height: 190),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.level = .floating
        window.center()
        window.isReleasedWhenClosed = false

        // Transparency + blur, like real NSAlerts.
        let visualEffectView = NSVisualEffectView()
        visualEffectView.frame = window.contentView!.bounds
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .popover
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 8

        window.contentView = visualEffectView

        let contentView = NSView(frame: visualEffectView.bounds)
        contentView.autoresizingMask = [.width, .height]
        visualEffectView.addSubview(contentView)

        // The app icon, 64×64 centred — as in an NSAlert.
        let iconImageView = NSImageView()
        iconImageView.frame = NSRect(x: (260 - 64) / 2, y: 106, width: 64, height: 64)
        iconImageView.image = NSApp.applicationIconImage
        iconImageView.imageScaling = .scaleProportionallyDown
        contentView.addSubview(iconImageView)

        // Main title (messageText).
        let titleLabel = NSTextField(labelWithString: L("setup.installation.title"))
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.alignment = .center
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 20, y: 66, width: 220, height: 20)
        contentView.addSubview(titleLabel)

        // Progress message (informativeText).
        let messageLabel = NSTextField(labelWithString: message)
        messageLabel.font = .systemFont(ofSize: 11)
        messageLabel.alignment = .center
        messageLabel.backgroundColor = .clear
        messageLabel.isBezeled = false
        messageLabel.isEditable = false
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byWordWrapping
        messageLabel.maximumNumberOfLines = 2
        messageLabel.frame = NSRect(x: 20, y: 33, width: 220, height: 30)
        contentView.addSubview(messageLabel)
        progressLabel = messageLabel

        // Progress bar (accessoryView).
        let progress = NSProgressIndicator()
        progress.style = .bar
        progress.isIndeterminate = true
        progress.frame = NSRect(x: 30, y: 7, width: 200, height: 28)
        progress.startAnimation(nil)
        contentView.addSubview(progress)
        progressIndicator = progress

        window.makeKeyAndOrderFront(nil)

        progressPanel = window
    }

    private func updateProgressMessage(_ message: String) {
        progressLabel?.stringValue = message
    }

    private func hideProgressPanel() {
        progressIndicator?.stopAnimation(nil)
        progressPanel?.close()
        progressPanel = nil
        progressLabel = nil
        progressIndicator = nil
    }
}

// MARK: - Supporting Types

struct RocVADDeviceInfo: Sendable {
    let index: Int
    let name: String
}

// MARK: - Parsing Helpers

private func parseDeviceIndex(from output: String) -> Int {
    let pattern = #"device #(\d+)"#
    let regex = try? NSRegularExpression(pattern: pattern)
    let range = NSRange(output.startIndex..<output.endIndex, in: output)

    if let match = regex?.firstMatch(in: output, range: range),
       let indexRange = Range(match.range(at: 1), in: output) {
        return Int(String(output[indexRange])) ?? 0
    }

    return 0
}

private func parseDeviceList(from output: String) -> [RocVADDeviceInfo] {
    var devices: [RocVADDeviceInfo] = []

    let lines = output.components(separatedBy: .newlines)
    for line in lines {
        let components = line.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
        if components.count >= 5,
           let index = Int(components[0]) {
            let name = components[4...].joined(separator: " ")
            devices.append(RocVADDeviceInfo(index: index, name: name))
        }
    }

    return devices
}
