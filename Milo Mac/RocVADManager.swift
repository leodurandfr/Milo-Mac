import Foundation
import AppKit

// MARK: - Progression

/// Ce que le pilote demande d'afficher pendant une opération. Le panneau, lui, est
/// dessiné par `RocVADManager`, sur le main thread.
enum RocVADProgress: Sendable {
    case show(String)
    case update(String)
    case hide
}

// MARK: - Pilote

/// Appels au binaire roc-vad, **sérialisés**.
///
/// La sérialisation n'est pas un détail de confort : chaque opération liste, supprime,
/// recrée puis configure le device « Milō ». Deux qui s'entrelacent laissent des doublons
/// ou un device à moitié configuré. Elle était portée par une `DispatchQueue` série et par
/// la discipline des appelants ; elle l'est maintenant par le compilateur.
///
/// L'exécuteur de cet acteur **est** cette même queue série (`DispatchSerialQueue` est
/// conforme à `SerialExecutor`). Ce n'est pas une coquetterie : les appels roc-vad sont
/// synchrones et bloquants (`Process.waitUntilExit`, plusieurs secondes quand le driver
/// répond mal). Sur l'exécuteur par défaut, ils bloqueraient un thread du pool coopératif
/// de Swift, dont la largeur est bornée par le nombre de cœurs. Ici ils bloquent un thread
/// de queue — exactement comme avant.
///
/// ⚠️ Aucune méthode de cet acteur ne doit contenir d'`await` : un point de suspension
/// rouvrirait la réentrance, donc l'entrelacement que la queue série interdisait. C'est
/// pourquoi la progression est **postée sans être attendue** — comme le faisait le
/// `DispatchQueue.main.async` d'origine.
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

    // MARK: - Sous-processus roc-vad

    /// Lance roc-vad et attend la fin. Synchrone et bloquant — d'où l'exécuteur ci-dessus.
    /// Renvoie nil si le binaire n'a pas pu être lancé (désinstallé en cours de session,
    /// par ex.) — contrairement à launch(), run() est rattrapable.
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

        // Lire avant waitUntilExit pour ne pas bloquer si la sortie remplit le pipe.
        let data = outputPipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()

        return (task.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Interface

    /// Le binaire est présent ET le driver répond. `roc-vad info` passe par gRPC et peut
    /// prendre plusieurs secondes quand le driver est à moitié chargé.
    func isFunctional() -> Bool {
        let working = RocVADManager.isBinaryInstalled && Self.runRocVAD(["info"])?.status == 0
        NSLog(working ? "✅ roc-vad is functional" : "⚠️ roc-vad missing or driver not loaded")
        return working
    }

    /// Installe roc-vad via osascript (qui affiche lui-même le dialogue d'autorisation
    /// administrateur). Bloquant : auth + curl + install.
    ///
    /// En sous-processus, et non via un `NSAppleScript` synchrone sur le main thread —
    /// celui-ci gelait le panneau de progression pendant toute l'installation.
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

    /// Vérifie le device et ne le (re)crée que si nécessaire — le cas courant (device déjà
    /// bon) ne montre aucun panneau.
    func configureIfNeeded(progress: @Sendable (RocVADProgress) -> Void) -> Bool {
        NSLog("🔧 Checking Milō audio device configuration...")

        let existing = deviceInfo().filter { $0.name == deviceName }

        // Doublons : tout supprimer et repartir proprement.
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

    /// Repointe le device sur l'IP résolue. roc-vad ne permet pas de modifier les endpoints
    /// d'un device existant : il faut le supprimer et le recréer.
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

    /// Applique de nouveaux réglages : le device est recréé avec les nouveaux arguments.
    func apply(_ newSettings: RocVADSettings, progress: @Sendable (RocVADProgress) -> Void) -> Bool {
        settings = newSettings

        if deleteAllMiloDevices() > 0 {
            // Court délai pour s'assurer que les devices sont bien supprimés.
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

    // MARK: - Primitives roc-vad

    /// Supprime tous les devices « Milō » et retourne le nombre supprimé.
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

    /// Le device a-t-il déjà ses endpoints ? On cherche les ports ROC caractéristiques,
    /// sans présumer de l'hôte (l'IP résolue peut différer de `miloHost`).
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

/// Façade du driver roc-vad : l'état côté UI (réglages, panneau de progression) et la
/// porte d'entrée du pilote.
///
/// roc-vad est un **état**, jamais un péage au démarrage : l'app tourne très bien sans
/// lui — seule la source « Mac » en dépend, et elle apparaît simplement désactivée.
@MainActor
final class RocVADManager {

    /// `nonisolated` : simple constante, lue depuis le pilote (hors main actor) comme
    /// depuis l'UI.
    nonisolated static let binaryPath = "/usr/local/bin/roc-vad"

    /// Le binaire est présent sur le disque (ne dit pas si le driver est chargé — pour ça,
    /// voir `checkInstallation()`).
    nonisolated static var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }

    /// Copie main-isolée des réglages, lue par SettingsViewModel. Le pilote garde la sienne
    /// (il en a besoin pour construire les arguments, sur sa propre queue).
    private(set) var settings: RocVADSettings

    private let device: RocVADDevice

    // Panneau de progression (style NSAlert natif)
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

    /// Vérifie le device et ne le (re)crée qu'au besoin. Le panneau de progression
    /// n'apparaît que si du travail est nécessaire.
    @discardableResult
    func configureDeviceOnly() async -> Bool {
        await device.configureIfNeeded(progress: progressSink())
    }

    /// Repointe roc-vad sur l'IP résolue. Sans attente : l'appelant (le connection manager)
    /// n'a rien à en faire.
    nonisolated func updateMiloHost(_ newHost: String) {
        Task { await device.updateHost(newHost) }
    }

    func performInstallation() async -> Bool {
        NSLog("🔧 Starting roc-vad installation...")

        showProgressPanel(message: L("progress.preparing"))
        defer { hideProgressPanel() }

        updateProgressMessage(L("progress.downloading"))
        guard await device.runInstaller() else { return false }

        // Laisser l'installation se poser, puis vérifier. `Task.sleep` et non
        // `Thread.sleep` : on est sur le main actor, et le panneau doit rester animé.
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

    /// Applique de nouveaux réglages et recrée le device.
    func updateSettings(_ newSettings: RocVADSettings) async -> Bool {
        NSLog("🔧 Updating ROC VAD settings...")

        // Poser la copie main-isolée AVANT le travail : c'est elle que lit
        // SettingsViewModel (`hasChanges`), et elle doit refléter ce qu'on est en train
        // d'appliquer dès le clic sur « Appliquer ».
        settings = newSettings
        newSettings.saveToUserDefaults()
        NSLog("💾 Settings saved: buffer=%dms, fec=%@, resampler=%@",
              newSettings.deviceBuffer, newSettings.fecEncoding.rawValue, newSettings.resamplerProfile.rawValue)

        showProgressPanel(message: L("progress.applying_settings"))
        defer { hideProgressPanel() }

        return await device.apply(newSettings, progress: progressSink())
    }

    // MARK: - Panneau de progression

    /// Le pilote poste ses étapes **sans les attendre** : un `await` vers le main actor
    /// depuis l'acteur le suspendrait, et rouvrirait l'entrelacement que sa queue série
    /// interdit. C'est exactement ce que faisait le `DispatchQueue.main.async` d'origine.
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

    // Fenêtre sans barre de titre, au matériau des NSAlert.
    private func showProgressPanel(message: String) {
        // Une opération peut en enchaîner une autre (updateSettings ouvre le panneau, puis
        // le pilote demande .show) : ne pas empiler deux fenêtres.
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

        // Transparence + flou, comme les vrais NSAlert.
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

        // Icône de l'app, 64×64 centrée — comme dans un NSAlert.
        let iconImageView = NSImageView()
        iconImageView.frame = NSRect(x: (260 - 64) / 2, y: 106, width: 64, height: 64)
        iconImageView.image = NSApp.applicationIconImage
        iconImageView.imageScaling = .scaleProportionallyDown
        contentView.addSubview(iconImageView)

        // Titre principal (messageText).
        let titleLabel = NSTextField(labelWithString: L("setup.installation.title"))
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.alignment = .center
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 20, y: 66, width: 220, height: 20)
        contentView.addSubview(titleLabel)

        // Message de progression (informativeText).
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

        // Barre de progression (accessoryView).
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
