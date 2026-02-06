import Foundation
import SwiftUI
import AppKit

class RocVADManager {

    private let deviceName = "Milō"
    private var miloHost = "milo.local"  // Mutable pour permettre la mise à jour avec l'IP résolue
    private let sourcePort = 10001
    private let repairPort = 10002
    private let controlPort = 10003

    // ROC VAD settings for sender configuration
    private(set) var settings: RocVADSettings

    // Window de progression (style NSAlert natif)
    private var progressPanel: NSWindow?
    private var progressLabel: NSTextField?
    private var progressIndicator: NSProgressIndicator?

    // MARK: - Initialization

    init() {
        self.settings = RocVADSettings.loadFromUserDefaults()
        NSLog("📦 RocVADManager initialized with settings: buffer=\(settings.deviceBuffer)ms, fec=\(settings.fecEncoding.rawValue), resampler=\(settings.resamplerProfile.rawValue)")
    }
    
    // MARK: - Public Interface
    
    func checkInstallation() -> Bool {
        NSLog("🔍 Checking roc-vad installation...")
        
        let rocVADPath = "/usr/local/bin/roc-vad"
        guard FileManager.default.fileExists(atPath: rocVADPath) else {
            NSLog("❌ roc-vad binary not found")
            return false
        }
        
        // Test simple de fonctionnalité (driver chargé)
        let task = Process()
        task.launchPath = rocVADPath
        task.arguments = ["info"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        
        task.launch()
        task.waitUntilExit()
        
        let isWorking = (task.terminationStatus == 0)
        NSLog(isWorking ? "✅ roc-vad is functional" : "⚠️ roc-vad binary exists but driver not loaded")
        
        return isWorking
    }
    
    func isDriverLoaded() -> Bool {
        let rocVADPath = "/usr/local/bin/roc-vad"
        guard FileManager.default.fileExists(atPath: rocVADPath) else {
            return false
        }
        
        let task = Process()
        task.launchPath = rocVADPath
        task.arguments = ["info"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        
        task.launch()
        task.waitUntilExit()
        
        return (task.terminationStatus == 0)
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
        
        // Première vérification silencieuse en background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }
            
            // Vérification rapide et silencieuse
            let deviceInfo = self.getRocVADDeviceInfo()
            
            if let existingDevice = deviceInfo.first(where: { $0.name == self.deviceName }) {
                NSLog("✅ Found existing Milō device (index: \(existingDevice.index))")
                
                let isConfigured = self.checkDeviceConfiguration(deviceIndex: existingDevice.index)
                
                if isConfigured {
                    NSLog("✅ Device already properly configured - no UI needed")
                    DispatchQueue.main.async { completion(true) }
                    return
                } else {
                    NSLog("🔧 Device needs reconfiguration - showing progress")
                    // Montrer la fenêtre et reconfigurer
                    DispatchQueue.main.async {
                        self.showProgressPanel(message: L("progress.reconfiguring_device"))
                    }
                    
                    let success = self.configureDevice(deviceIndex: existingDevice.index)
                    DispatchQueue.main.async {
                        self.hideProgressPanel()
                        completion(success)
                    }
                }
            } else {
                NSLog("❌ No Milō device found - showing progress and creating new one")
                // Montrer la fenêtre et créer + configurer
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
                
                NSLog("✅ Created new Milō device with index: \(deviceIndex)")
                let success = self.configureDevice(deviceIndex: deviceIndex)
                
                DispatchQueue.main.async {
                    self.hideProgressPanel()
                    completion(success)
                }
            }
        }
    }
    
    func waitForDriverInitialization(completion: @escaping (Bool) -> Void) {
        NSLog("⏳ Starting driver initialization wait...")

        // Créer panel d'attente
        showProgressPanel(message: L("progress.driver_waiting"))

        // Démarrer les tentatives en background
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let success = self?.performDriverWaitRetries() ?? false

            DispatchQueue.main.async {
                self?.hideProgressPanel()
                completion(success)
            }
        }
    }

    /// Met à jour l'adresse de Milo avec l'IP résolue et reconfigure le device roc-vad
    /// - Parameter newHost: L'adresse IP résolue (ex: "192.168.1.73")
    func updateMiloHost(_ newHost: String) {
        guard newHost != miloHost else {
            NSLog("🔄 roc-vad: Host unchanged (\(newHost))")
            return
        }

        NSLog("🔄 Updating roc-vad endpoint from \(miloHost) to \(newHost)")
        miloHost = newHost

        // Supprimer et recréer le device avec la nouvelle adresse en background
        // (roc-vad ne permet pas de modifier les endpoints d'un device existant)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            let deviceInfo = self.getRocVADDeviceInfo()
            if let existingDevice = deviceInfo.first(where: { $0.name == self.deviceName }) {
                NSLog("🗑️ Deleting existing device #\(existingDevice.index) to reconfigure with IP")
                self.deleteDevice(deviceIndex: existingDevice.index)
            }

            // Créer un nouveau device
            let newDeviceIndex = self.createMiloDevice()
            guard newDeviceIndex > 0 else {
                NSLog("❌ Failed to create new Milō device")
                return
            }

            NSLog("🔧 Configuring new device #\(newDeviceIndex) with IP: \(newHost)")
            let success = self.configureDevice(deviceIndex: newDeviceIndex)
            NSLog(success ? "✅ Device reconfigured with IP: \(newHost)" : "❌ Failed to configure device with IP: \(newHost)")
        }
    }

    // MARK: - Settings Management

    /// Update ROC VAD settings and recreate the device with new configuration
    /// - Parameters:
    ///   - newSettings: The new settings to apply
    ///   - completion: Callback with success status
    func updateSettings(_ newSettings: RocVADSettings, completion: @escaping (Bool) -> Void) {
        NSLog("🔧 Updating ROC VAD settings...")

        // Show progress panel
        DispatchQueue.main.async {
            self.showProgressPanel(message: L("progress.applying_settings"))
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else {
                DispatchQueue.main.async { completion(false) }
                return
            }

            // Save new settings
            self.settings = newSettings
            newSettings.saveToUserDefaults()
            NSLog("💾 Settings saved: buffer=\(newSettings.deviceBuffer)ms, fec=\(newSettings.fecEncoding.rawValue), resampler=\(newSettings.resamplerProfile.rawValue)")

            // Find and delete existing device
            let deviceInfo = self.getRocVADDeviceInfo()
            if let existingDevice = deviceInfo.first(where: { $0.name == self.deviceName }) {
                NSLog("🗑️ Deleting existing device #\(existingDevice.index) for reconfiguration")
                self.deleteDevice(deviceIndex: existingDevice.index)
                // Small delay to ensure device is fully removed
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Create new device with updated settings
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

            NSLog("✅ Created new device #\(newDeviceIndex) with updated settings")

            // Configure endpoints
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
        let task = Process()
        task.launchPath = "/usr/local/bin/roc-vad"
        task.arguments = ["device", "del", "\(deviceIndex)"]
        task.standardOutput = Pipe()
        task.standardError = Pipe()

        task.launch()
        task.waitUntilExit()

        let success = (task.terminationStatus == 0)
        NSLog(success ? "✅ Device #\(deviceIndex) deleted" : "⚠️ Failed to delete device #\(deviceIndex)")
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
        
        // Icône de l'app (comme dans NSAlert) - 60x60 centré (+8px par rapport à 52x52)
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
        
        // Exécuter l'installation
        DispatchQueue.main.sync {
            let appleScript = NSAppleScript(source: script)
            appleScript?.executeAndReturnError(nil)
        }
        
        // Attendre un peu pour que l'installation se termine
        Thread.sleep(forTimeInterval: 3.0)
        
        updateProgressMessage(L("progress.verifying"))
        Thread.sleep(forTimeInterval: 1.0)
        
        // Vérifier que l'installation a réussi
        let rocVADPath = "/usr/local/bin/roc-vad"
        let success = FileManager.default.fileExists(atPath: rocVADPath)
        
        if success {
            updateProgressMessage(L("progress.installation_complete"))
            Thread.sleep(forTimeInterval: 1.0)
            NSLog(L("log.installation_success"))
        } else {
            NSLog(L("log.installation_failed"))
        }
        
        return success
    }
    
    // MARK: - Driver Wait Process
    
    private func performDriverWaitRetries() -> Bool {
        let retryDelays = [2.0, 5.0, 8.0, 12.0, 15.0] // Total ~42 secondes
        var attemptCount = 0
        
        for delay in retryDelays {
            attemptCount += 1
            
            updateProgressMessage(L("progress.driver_waiting_attempt", attemptCount, retryDelays.count))
            NSLog("🔄 Driver wait attempt \(attemptCount)/\(retryDelays.count)")
            
            // Attendre avant de tester
            Thread.sleep(forTimeInterval: delay)
            
            // Tester si le driver est maintenant fonctionnel
            let task = Process()
            task.launchPath = "/usr/local/bin/roc-vad"
            task.arguments = ["info"]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            
            task.launch()
            task.waitUntilExit()
            
            if task.terminationStatus == 0 {
                NSLog("✅ Driver became available after \(attemptCount) attempts")
                updateProgressMessage(L("progress.driver_initialized"))
                Thread.sleep(forTimeInterval: 1.0)
                return true
            }
        }
        
        NSLog("❌ Driver still not available after \(attemptCount) attempts")
        return false
    }
    
    private func ensureDeviceConfigured() -> Bool {
        let deviceInfo = getRocVADDeviceInfo()
        
        if let existingDevice = deviceInfo.first(where: { $0.name == deviceName }) {
            NSLog("✅ Found existing Milō device (index: \(existingDevice.index))")
            
            let isConfigured = checkDeviceConfiguration(deviceIndex: existingDevice.index)
            
            if isConfigured {
                NSLog("✅ Device already properly configured")
                return true
            } else {
                NSLog("🔧 Reconfiguring existing device...")
                return configureDevice(deviceIndex: existingDevice.index)
            }
        } else {
            NSLog("❌ No Milō device found, creating new one...")
            
            let deviceIndex = createMiloDevice()
            
            guard deviceIndex > 0 else {
                NSLog("❌ Failed to create Milō device")
                return false
            }
            
            NSLog("✅ Created new Milō device with index: \(deviceIndex)")
            return configureDevice(deviceIndex: deviceIndex)
        }
    }
    
    private func createMiloDevice() -> Int {
        let task = Process()
        task.launchPath = "/usr/local/bin/roc-vad"

        // Base arguments
        var arguments = ["device", "add", "sender", "--name", deviceName]

        // Add settings arguments
        arguments.append(contentsOf: settings.toDeviceArguments())

        task.arguments = arguments
        NSLog("🔧 Creating device with arguments: \(arguments.joined(separator: " "))")

        let pipe = Pipe()
        task.standardOutput = pipe

        let semaphore = DispatchSemaphore(value: 0)
        var deviceIndex = 0

        task.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            deviceIndex = parseDeviceIndex(from: output)
            semaphore.signal()
        }

        task.launch()
        semaphore.wait()

        return deviceIndex
    }
    
    private func configureDevice(deviceIndex: Int) -> Bool {
        let task = Process()
        task.launchPath = "/usr/local/bin/roc-vad"
        task.arguments = [
            "device", "connect", "\(deviceIndex)",
            "--source", "rtp+rs8m://\(miloHost):\(sourcePort)",
            "--repair", "rs8m://\(miloHost):\(repairPort)",
            "--control", "rtcp://\(miloHost):\(controlPort)"
        ]
        
        let semaphore = DispatchSemaphore(value: 0)
        var success = false
        
        task.terminationHandler = { _ in
            success = (task.terminationStatus == 0)
            semaphore.signal()
        }
        
        task.launch()
        semaphore.wait()
        
        NSLog(success ? "✅ Device configured successfully" : "❌ Device configuration failed")
        return success
    }
    
    private func checkDeviceConfiguration(deviceIndex: Int) -> Bool {
        let task = Process()
        task.launchPath = "/usr/local/bin/roc-vad"
        task.arguments = ["device", "show", "\(deviceIndex)"]

        let pipe = Pipe()
        task.standardOutput = pipe

        let semaphore = DispatchSemaphore(value: 0)
        var isConfigured = false

        task.terminationHandler = { [self] _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            // Vérifier si le device a des endpoints configurés (soit avec miloHost actuel, soit avec une IP)
            // On vérifie la présence des ports ROC caractéristiques
            let hasSourcePort = output.contains(":\(sourcePort)")
            let hasRepairPort = output.contains(":\(repairPort)")
            let hasControlPort = output.contains(":\(controlPort)")
            isConfigured = hasSourcePort && hasRepairPort && hasControlPort
            semaphore.signal()
        }

        task.launch()
        semaphore.wait()

        return isConfigured
    }
    
    private func getRocVADDeviceInfo() -> [RocVADDeviceInfo] {
        let task = Process()
        task.launchPath = "/usr/local/bin/roc-vad"
        task.arguments = ["device", "list"]
        
        let pipe = Pipe()
        task.standardOutput = pipe
        
        let semaphore = DispatchSemaphore(value: 0)
        var devices: [RocVADDeviceInfo] = []
        
        task.terminationHandler = { _ in
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            devices = parseDeviceList(from: output)
            semaphore.signal()
        }
        
        task.launch()
        semaphore.wait()
        
        return devices
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
