import Foundation
import SwiftUI
import AppKit

class RocVADManager {

    static let binaryPath = "/usr/local/bin/roc-vad"

    /// Le binaire est présent sur le disque (ne dit pas si le driver est chargé —
    /// pour ça, voir checkInstallation).
    static var isBinaryInstalled: Bool {
        FileManager.default.fileExists(atPath: binaryPath)
    }

    private let deviceName = "Milō"
    private var miloHost = "milo.local"  // Muté uniquement sur deviceQueue
    private let sourcePort = 10001
    private let repairPort = 10002
    private let controlPort = 10003

    // Paramètres ROC VAD pour la configuration du sender
    private(set) var settings: RocVADSettings

    // Queue série pour éviter les opérations concurrentes sur les devices (race condition entre configureDeviceOnly et updateMiloHost)
    private let deviceQueue = DispatchQueue(label: "com.milo.rocvad.device")

    // Window de progression (style NSAlert natif)
    private var progressPanel: NSWindow?
    private var progressLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?

    // MARK: - Initialization

    init() {
        self.settings = RocVADSettings.loadFromUserDefaults()
        NSLog("📦 RocVADManager initialized with settings: buffer=%dms, fec=%@, resampler=%@", settings.deviceBuffer, settings.fecEncoding.rawValue, settings.resamplerProfile.rawValue)
    }

    // MARK: - roc-vad subprocess helper

    /// Lance roc-vad avec les arguments donnés et attend la fin. Synchrone —
    /// à appeler hors du main thread (deviceQueue ou queue globale).
    /// Renvoie nil si le binaire n'a pas pu être lancé (désinstallé en cours
    /// de session, par ex.) — contrairement à launch(), run() est rattrapable.
    private static func runRocVAD(_ arguments: [String]) -> (status: Int32, output: String)? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: binaryPath)
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

    // MARK: - Public Interface

    /// Vérifie que le binaire est présent ET que le driver répond (`roc-vad info`
    /// passe par gRPC et peut prendre plusieurs secondes quand le driver est
    /// à moitié chargé) — d'où l'exécution hors main thread.
    /// Le completion est appelé sur le main thread.
    func checkInstallation(completion: @escaping (Bool) -> Void) {
        deviceQueue.async {
            let isWorking = Self.isBinaryInstalled && Self.runRocVAD(["info"])?.status == 0
            NSLog(isWorking ? "✅ roc-vad is functional" : "⚠️ roc-vad missing or driver not loaded")
            DispatchQueue.main.async { completion(isWorking) }
        }
    }

    func performInstallation(completion: @escaping (Bool) -> Void) {
        NSLog("🔧 Starting roc-vad installation...")

        // Créer panel de progression (style NSAlert)
        showProgressPanel(message: L("progress.preparing"))

        // Installation en background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let installSuccess = self?.installRocVAD() ?? false

            DispatchQueue.main.async {
                self?.hideProgressPanel()
                completion(installSuccess)
            }
        }
    }

    func configureDeviceOnly(completion: @escaping (Bool) -> Void) {
        NSLog("🔧 Checking Milō audio device configuration...")

        // Queue série pour éviter les race conditions avec updateMiloHost
        deviceQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Supprimer les éventuels doublons, ne garder qu'un seul device
            let deviceInfo = self.getRocVADDeviceInfo()
            let existingDevices = deviceInfo.filter { $0.name == self.deviceName }

            // S'il y a des doublons, tout supprimer et recréer proprement
            if existingDevices.count > 1 {
                NSLog("⚠️ Found %d Milō devices - cleaning up duplicates", existingDevices.count)
                self.deleteAllMiloDevices()
            } else if let existingDevice = existingDevices.first {
                NSLog("✅ Found existing Milō device (index: %d)", existingDevice.index)

                let isConfigured = self.checkDeviceConfiguration(deviceIndex: existingDevice.index)

                if isConfigured {
                    NSLog("✅ Device already properly configured - no UI needed")
                    DispatchQueue.main.async { completion(true) }
                    return
                } else {
                    NSLog("🔧 Device needs reconfiguration - showing progress")
                    DispatchQueue.main.async {
                        self.showProgressPanel(message: L("progress.reconfiguring_device"))
                    }

                    let success = self.configureDevice(deviceIndex: existingDevice.index)
                    DispatchQueue.main.async {
                        self.hideProgressPanel()
                        completion(success)
                    }
                    return
                }
            }

            // Aucun device ou doublons nettoyés → créer un nouveau
            NSLog("❌ No Milō device found - showing progress and creating new one")
            DispatchQueue.main.async {
                self.showProgressPanel(message: L("progress.creating_device"))
            }

            let deviceIndex = self.createMiloDevice()

            guard deviceIndex > 0 else {
                NSLog("❌ Failed to create Milō device")
                DispatchQueue.main.async {
                    self.hideProgressPanel()
                    completion(false)
                }
                return
            }

            NSLog("✅ Created new Milō device with index: %d", deviceIndex)
            let success = self.configureDevice(deviceIndex: deviceIndex)

            DispatchQueue.main.async {
                self.hideProgressPanel()
                completion(success)
            }
        }
    }

    /// Met à jour l'adresse de Milo avec l'IP résolue et reconfigure le device roc-vad
    /// - Parameter newHost: L'adresse IP résolue (ex: "192.168.1.73")
    func updateMiloHost(_ newHost: String) {
        // Supprimer et recréer le device avec la nouvelle adresse
        // (roc-vad ne permet pas de modifier les endpoints d'un device existant).
        // La comparaison ET la mutation de miloHost se font sur deviceQueue :
        // une lecture hors queue racerait avec l'écriture sérialisée.
        deviceQueue.async { [weak self] in
            guard let self = self else { return }

            guard newHost != self.miloHost else {
                NSLog("🔄 roc-vad: Host unchanged (%@)", newHost)
                return
            }

            NSLog("🔄 Updating roc-vad endpoint from %@ to %@", self.miloHost, newHost)
            self.miloHost = newHost

            self.deleteAllMiloDevices()

            // Créer un nouveau device
            let newDeviceIndex = self.createMiloDevice()
            guard newDeviceIndex > 0 else {
                NSLog("❌ Failed to create new Milō device")
                return
            }

            NSLog("🔧 Configuring new device #%d with IP: %@", newDeviceIndex, newHost)
            let success = self.configureDevice(deviceIndex: newDeviceIndex)
            NSLog(success ? "✅ Device reconfigured with IP: %@" : "❌ Failed to configure device with IP: %@", newHost)
        }
    }

    // MARK: - Settings Management

    /// Met à jour les paramètres ROC VAD et recrée le device avec la nouvelle configuration
    /// - Parameters:
    ///   - newSettings: Les nouveaux paramètres à appliquer
    ///   - completion: Callback avec le statut de succès
    func updateSettings(_ newSettings: RocVADSettings, completion: @escaping (Bool) -> Void) {
        NSLog("🔧 Updating ROC VAD settings...")

        // Sauvegarder ici (thread appelant = main) : `settings` est lu sur le
        // main thread par SettingsViewModel — l'écrire depuis deviceQueue
        // racerait avec ces lectures. createMiloDevice (sur deviceQueue) verra
        // la nouvelle valeur via le happens-before du dispatch ci-dessous.
        self.settings = newSettings
        newSettings.saveToUserDefaults()
        NSLog("💾 Settings saved: buffer=%dms, fec=%@, resampler=%@", newSettings.deviceBuffer, newSettings.fecEncoding.rawValue, newSettings.resamplerProfile.rawValue)

        // Afficher le panel de progression
        showProgressPanel(message: L("progress.applying_settings"))

        deviceQueue.async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Supprimer tous les devices Milō existants
            let deleted = self.deleteAllMiloDevices()
            if deleted > 0 {
                // Court délai pour s'assurer que les devices sont bien supprimés
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Créer un nouveau device avec les paramètres mis à jour
            DispatchQueue.main.async {
                self.updateProgressMessage(L("progress.creating_device"))
            }

            let newDeviceIndex = self.createMiloDevice()
            guard newDeviceIndex > 0 else {
                NSLog("❌ Failed to create new device with updated settings")
                DispatchQueue.main.async {
                    self.hideProgressPanel()
                    completion(false)
                }
                return
            }

            NSLog("✅ Created new device #%d with updated settings", newDeviceIndex)

            // Configurer les endpoints
            DispatchQueue.main.async {
                self.updateProgressMessage(L("progress.reconfiguring_device"))
            }

            let success = self.configureDevice(deviceIndex: newDeviceIndex)

            DispatchQueue.main.async {
                self.hideProgressPanel()
                NSLog(success ? "✅ Device reconfigured with new settings" : "❌ Failed to configure device endpoints")
                completion(success)
            }
        }
    }

    /// Supprime un device roc-vad par son index
    private func deleteDevice(deviceIndex: Int) {
        let success = Self.runRocVAD(["device", "del", "\(deviceIndex)"])?.status == 0
        NSLog(success ? "✅ Device #%d deleted" : "⚠️ Failed to delete device #%d", deviceIndex)
    }

    // MARK: - Progress Window Management (Style NSAlert natif avec Hidden Title Bar)

    private func showProgressPanel(message: String) {
        // Créer une NSWindow avec Hidden Title Bar et effet visuel NSAlert
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

        // Ajouter l'effet visuel NSAlert (transparence + flou comme les vrais NSAlert)
        let visualEffectView = NSVisualEffectView()
        visualEffectView.frame = window.contentView!.bounds
        visualEffectView.autoresizingMask = [.width, .height]
        visualEffectView.material = .popover  // Material identique aux NSAlert
        visualEffectView.state = .active
        visualEffectView.wantsLayer = true
        visualEffectView.layer?.cornerRadius = 8

        window.contentView = visualEffectView

        // Container pour le contenu
        let contentView = NSView(frame: visualEffectView.bounds)
        contentView.autoresizingMask = [.width, .height]
        visualEffectView.addSubview(contentView)

        // Icône de l'app (comme dans NSAlert) - 64x64 centré
        let iconImageView = NSImageView()
        iconImageView.frame = NSRect(x: (260 - 64) / 2, y: 106, width: 64, height: 64)
        iconImageView.image = NSApp.applicationIconImage
        iconImageView.imageScaling = .scaleProportionallyDown
        contentView.addSubview(iconImageView)

        // Titre principal (comme messageText dans NSAlert) - 12px de marge supplémentaire sous l'icône
        let titleLabel = NSTextField(labelWithString: L("setup.installation.title"))
        titleLabel.font = .boldSystemFont(ofSize: 13)
        titleLabel.alignment = .center
        titleLabel.backgroundColor = .clear
        titleLabel.isBezeled = false
        titleLabel.isEditable = false
        titleLabel.textColor = .labelColor
        titleLabel.frame = NSRect(x: 20, y: 66, width: 220, height: 20)
        contentView.addSubview(titleLabel)

        // Message de progression (comme informativeText dans NSAlert)
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

        // Barre de progression (comme accessoryView dans NSAlert)
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
        DispatchQueue.main.async { [weak self] in
            self?.progressLabel?.stringValue = message
        }
    }

    private func hideProgressPanel() {
        progressIndicator?.stopAnimation(nil)
        progressPanel?.close()
        progressPanel = nil
        progressLabel = nil
        progressIndicator = nil
    }

    // MARK: - Installation Process

    private func installRocVAD() -> Bool {
        NSLog("📦 Installing roc-vad...")

        updateProgressMessage(L("progress.downloading"))

        let script = """
        do shell script "sudo /bin/bash -c \\"$(curl -fsSL https://raw.githubusercontent.com/roc-streaming/roc-vad/HEAD/install.sh)\\"" with administrator privileges
        """

        // Exécuter via osascript en subprocess sur CETTE queue (background) :
        // un NSAppleScript synchrone sur le main thread gelait le panel de
        // progression pendant toute la durée auth + curl + install. osascript
        // affiche lui-même le dialogue d'autorisation administrateur.
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

        // Attendre un peu pour que l'installation se termine
        Thread.sleep(forTimeInterval: 3.0)

        updateProgressMessage(L("progress.verifying"))
        Thread.sleep(forTimeInterval: 1.0)

        // Vérifier que l'installation a réussi
        let success = Self.isBinaryInstalled

        if success {
            updateProgressMessage(L("progress.installation_complete"))
            Thread.sleep(forTimeInterval: 1.0)
            NSLog("✅ roc-vad installation completed")
        } else {
            NSLog("❌ roc-vad installation failed")
        }

        return success
    }

    /// Supprime tous les devices roc-vad nommés "Milō" et retourne le nombre supprimé
    @discardableResult
    private func deleteAllMiloDevices() -> Int {
        let existing = getRocVADDeviceInfo().filter { $0.name == deviceName }
        for device in existing {
            NSLog("🗑️ Deleting device #%d", device.index)
            deleteDevice(deviceIndex: device.index)
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

    private func checkDeviceConfiguration(deviceIndex: Int) -> Bool {
        guard let result = Self.runRocVAD(["device", "show", "\(deviceIndex)"]) else { return false }

        // Vérifier si le device a des endpoints configurés (soit avec miloHost actuel, soit avec une IP)
        // On vérifie la présence des ports ROC caractéristiques
        let output = result.output
        return output.contains(":\(sourcePort)")
            && output.contains(":\(repairPort)")
            && output.contains(":\(controlPort)")
    }

    private func getRocVADDeviceInfo() -> [RocVADDeviceInfo] {
        guard let result = Self.runRocVAD(["device", "list"]) else { return [] }
        return parseDeviceList(from: result.output)
    }
}

// MARK: - Supporting Types

struct RocVADDeviceInfo {
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
