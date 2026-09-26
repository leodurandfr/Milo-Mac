import Foundation
import AppKit
import Observation

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
/// reentrancy, hence the interleaving the serial queue forbade.
actor RocVADDevice {
    private let queue = DispatchSerialQueue(label: "com.milo.rocvad.device")
    nonisolated var unownedExecutor: UnownedSerialExecutor { queue.asUnownedSerialExecutor() }

    private let deviceName = "Milō"
    private let sourcePort = 10001
    private let repairPort = 10002
    private let controlPort = 10003

    /// Past this a roc-vad call is killed and counted as failed. A healthy driver answers in
    /// well under a second and a slow one was measured at 7.7 s; one that does not answer at
    /// all (it hung inside coreaudiod on 2026-09-26) must not hold this queue — and every
    /// later call behind it — forever.
    private static let callTimeout: TimeInterval = 15

    /// The newest `ensure` handled. One queued behind it describes a link that no longer
    /// stands, and would rebuild the device a second time for nothing.
    private var handledGeneration = 0

    // MARK: - roc-vad subprocess

    /// Runs roc-vad and waits for it to finish, at most `callTimeout`. Synchronous and
    /// blocking — hence the executor above. Nil when the binary could not be launched
    /// (uninstalled mid-session) or did not answer in time.
    private nonisolated static func runRocVAD(_ arguments: [String]) -> (status: Int32, output: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: RocVADManager.binaryPath)
        task.arguments = arguments

        let outputPipe = Pipe()
        task.standardOutput = outputPipe
        task.standardError = Pipe()

        let finished = DispatchSemaphore(value: 0)
        task.terminationHandler = { _ in finished.signal() }

        do {
            try task.run()
        } catch {
            NSLog("❌ roc-vad launch failed: %@", String(describing: error))
            return nil
        }

        if finished.wait(timeout: .now() + callTimeout) == .timedOut {
            task.terminate()
            finished.wait()
            NSLog("❌ roc-vad %@ did not answer within %.0f s — killed", arguments.first ?? "", callTimeout)
            return nil
        }

        // roc-vad writes a few lines at most, well within a pipe's buffer, so reading after
        // the exit cannot have blocked it.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
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

    /// At launch, before Milō is known: duplicates left by an earlier run go, a single
    /// device is kept as it is. `ensure` builds or corrects it once Milō has said where it
    /// is and how the link is set.
    func removeDuplicates() {
        let existing = deviceInfo().filter { $0.name == deviceName }
        guard existing.count > 1 else { return }
        NSLog("⚠️ Found %d Milō devices - removing them", existing.count)
        deleteAllMiloDevices()
    }

    /// Makes the Milō device send to `host` with `settings`, rebuilding it only when it does
    /// not already: a rebuild takes the output away from whoever is listening.
    ///
    /// roc-vad cannot change a device in place, so a rebuild is delete + create + connect,
    /// under a fresh UID. When Milō was the default output, it is made the default again.
    func ensure(host: String, settings: RocVADSettings, generation: Int) -> Bool {
        guard generation > handledGeneration else { return true }
        handledGeneration = generation

        let existing = deviceInfo().filter { $0.name == deviceName }
        if existing.count == 1,
           let shown = Self.runRocVAD(["device", "show", "\(existing[0].index)"]), shown.status == 0,
           RocVADDeviceDescription(showOutput: shown.output)
               .matches(host: host, sourcePort: sourcePort, settings: settings) {
            NSLog("✅ roc-vad: the Milō device already sends to %@ as Milō set it", host)
            return true
        }

        let currentOutput = SystemAudioOutput.defaultOutputUID()
        let miloWasTheOutput = existing.contains { $0.uid == currentOutput }

        if deleteAllMiloDevices() > 0 {
            // A short delay to make sure the devices really are deleted.
            Thread.sleep(forTimeInterval: 0.5)
        }

        let index = createMiloDevice(settings)
        guard index > 0 else {
            NSLog("❌ Failed to create the Milō device")
            return false
        }
        guard connect(deviceIndex: index, host: host) else { return false }
        NSLog("✅ Milō device #%d sends to %@ (%@)", index, host, settings.toDeviceArguments().joined(separator: " "))

        if miloWasTheOutput, let uid = deviceInfo().first(where: { $0.index == index })?.uid {
            restoreOutput(uid: uid)
        }
        return true
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

    private func createMiloDevice(_ settings: RocVADSettings) -> Int {
        var arguments = ["device", "add", "sender", "--name", deviceName]
        arguments.append(contentsOf: settings.toDeviceArguments())

        NSLog("🔧 Creating device with arguments: %@", arguments.joined(separator: " "))

        guard let result = Self.runRocVAD(arguments) else { return 0 }
        return parseDeviceIndex(from: result.output)
    }

    private func connect(deviceIndex: Int, host: String) -> Bool {
        let result = Self.runRocVAD([
            "device", "connect", "\(deviceIndex)",
            "--source", "rtp+rs8m://\(host):\(sourcePort)",
            "--repair", "rs8m://\(host):\(repairPort)",
            "--control", "rtcp://\(host):\(controlPort)"
        ])

        let success = result?.status == 0
        NSLog(success ? "✅ Device configured successfully" : "❌ Device configuration failed")
        return success
    }

    /// CoreAudio publishes a new device a moment after roc-vad creates it, hence the retries.
    private func restoreOutput(uid: String) {
        for _ in 0..<15 {
            if SystemAudioOutput.setDefaultOutput(uid: uid) {
                NSLog("🔊 Milō is the sound output again")
                return
            }
            Thread.sleep(forTimeInterval: 0.2)
        }
        NSLog("⚠️ Could not make the new Milō device the sound output")
    }

    private func deviceInfo() -> [RocVADDeviceInfo] {
        guard let result = Self.runRocVAD(["device", "list"]) else { return [] }
        return parseDeviceList(from: result.output)
    }
}

// MARK: - Manager

/// The roc-vad driver's façade on the main actor: what Milō asked for, and the progress panel
/// of the one operation that shows one, the installation.
///
/// roc-vad is a **state**, never a toll at startup: the app runs perfectly well without it
/// — only the "Mac" source depends on it, and it simply shows up as disabled.
///
/// The device follows Milō: its host from the connection, its sender settings from Milō's
/// `mac_roc`. Neither is edited here, and nothing is persisted — the device itself holds the
/// last configuration, and Milō sends the current one on every connection.
@MainActor
@Observable
final class RocVADManager {

    /// `nonisolated`: a plain constant, read from the driver layer (off the main actor) as
    /// well as from the UI.
    nonisolated static let binaryPath = "/usr/local/bin/roc-vad"

    /// The binary is present on disk (this says nothing about whether the driver is
    /// loaded — for that, see `checkInstallation()`).
    nonisolated static var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }

    /// The sender half Milō last sent, shown read-only in Settings. Nil until Milō answered.
    private(set) var settings: RocVADSettings?

    @ObservationIgnored private var host: String?
    @ObservationIgnored private var driverReady = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let device = RocVADDevice()

    // Progress panel (native NSAlert styling)
    @ObservationIgnored private var progressPanel: NSWindow?
    @ObservationIgnored private var progressLabel: NSTextField?
    @ObservationIgnored private var progressIndicator: NSProgressIndicator?

    // MARK: - Interface

    func checkInstallation() async -> Bool {
        await device.isFunctional()
    }

    /// The driver answers: duplicates from an earlier run go, and the device is brought in
    /// line with Milō as soon as both its host and its link are known.
    func driverIsReady() async {
        driverReady = true
        await device.removeDuplicates()
        reconcile()
    }

    /// Where Milō answers, from the connection manager.
    func updateMiloHost(_ newHost: String) {
        host = newHost
        reconcile()
    }

    /// The sender half of Milō's link, from `/bulk` at connect or `settings/mac_roc_changed`.
    func applyFromMilo(_ newSettings: RocVADSettings) {
        settings = newSettings
        reconcile()
    }

    /// Hands the driver layer the link as it now stands. Not awaited: the host and the link
    /// arrive separately, and the generation lets the actor drop a request overtaken by a
    /// newer one rather than rebuild the device twice.
    private func reconcile() {
        guard driverReady, let host, let settings else { return }
        generation += 1
        let generation = generation
        Task { [device] in
            let applied = await device.ensure(host: host, settings: settings, generation: generation)
            if !applied {
                NSLog("⚠️ roc-vad: the Milō device could not be set as Milō asks")
            }
        }
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

    // MARK: - Progress panel

    // A title-bar-less window, in the NSAlert material.
    private func showProgressPanel(message: String) {
        // Never two windows for one installation.
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
    let uid: String
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
            devices.append(RocVADDeviceInfo(index: index, uid: components[3], name: name))
        }
    }

    return devices
}
