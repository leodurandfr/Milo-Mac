import SwiftUI
import ServiceManagement

@main
struct Milo_MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var menuBarController: MenuBarController?
    var rocVADManager: RocVADManager?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        
        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.setActivationPolicy(.accessory)
        }
        
        NSLog(L("log.milo_starting"))
        
        // Démarrer le processus d'installation/setup
        startSetupProcess()
    }
    
    private func startSetupProcess() {
        rocVADManager = RocVADManager()
        
        // Vérifier si roc-vad est installé ET que le driver est chargé
        if rocVADManager!.checkInstallation() {
            NSLog("✅ roc-vad installed and driver loaded - configuring device")
            configureDeviceAndStart()
        } else if FileManager.default.fileExists(atPath: "/usr/local/bin/roc-vad") {
            NSLog("⚠️ roc-vad installed but driver not loaded - waiting for initialization")
            waitForDriverAndConfigure()
        } else {
            NSLog("❓ roc-vad not installed - showing setup choice")
            showInitialChoice()
        }
    }
    
    private func waitForDriverAndConfigure() {
        NSLog("⏳ Waiting for roc-vad driver to initialize...")
        
        rocVADManager!.waitForDriverInitialization { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    NSLog("✅ Driver initialized successfully - configuring device")
                    self?.configureDeviceAndStart()
                } else {
                    NSLog("⚠️ Driver initialization timeout - showing alternatives")
                    self?.showDriverTimeoutAlert()
                }
            }
        }
    }
    
    private func configureDeviceAndStart() {
        rocVADManager!.configureDeviceOnly { [weak self] success in
            if success {
                NSLog("✅ Device configured successfully")
            } else {
                NSLog("⚠️ Device configuration failed, continuing anyway")
            }
            
            self?.initializeMiloApp()
        }
    }
    
    private func showDriverTimeoutAlert() {
        let alert = NSAlert()
        alert.messageText = L("setup.initialization.title")
        alert.informativeText = L("setup.driver.timeout.message")
        alert.addButton(withTitle: L("setup.driver.timeout.continue"))
        alert.addButton(withTitle: L("setup.driver.timeout.restart"))
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Continuer sans audio Mac
            initializeMiloApp()
        } else {
            // Redémarrer
            restartMac()
        }
    }
    
    private func showDriverNotLoadedAlert() {
        let alert = NSAlert()
        alert.messageText = L("setup.restart.required")
        alert.informativeText = L("setup.restart.message")
        alert.addButton(withTitle: L("setup.restart.now"))
        alert.addButton(withTitle: L("setup.restart.continue_without"))
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            restartMac()
        } else {
            initializeMiloApp()
        }
    }
    
    private func showInitialChoice() {
        let alert = NSAlert()
        alert.messageText = L("setup.main.title")
        alert.informativeText = L("setup.main.message")
        alert.addButton(withTitle: L("setup.main.install_button"))
        alert.addButton(withTitle: L("setup.main.cancel_button"))
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            NSLog("🔧 User chose to install roc-vad")
            startInstallationProcess()
        } else {
            NSLog("❌ User cancelled installation")
            NSApplication.shared.terminate(nil)
        }
    }
    
    private func startInstallationProcess() {
        guard let rocVADManager = rocVADManager else {
            initializeMiloApp()
            return
        }
        
        // Installer avec retour visuel
        rocVADManager.performInstallation { [weak self] success in
            DispatchQueue.main.async {
                if success {
                    self?.showRestartChoice()
                } else {
                    self?.showInstallationError()
                }
            }
        }
    }
    
    private func showRestartChoice() {
        let alert = NSAlert()
        alert.messageText = L("setup.installation.completed")
        alert.informativeText = L("setup.installation.completed.message")
        alert.addButton(withTitle: L("setup.installation.completed.restart_auto"))
        alert.addButton(withTitle: L("setup.installation.completed.restart_later"))
        alert.alertStyle = .informational
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            // Activer launch at login puis redémarrer
            enableLaunchAtLogin()
            restartMac()
        } else {
            // Redémarrer plus tard - quitter l'app
            NSLog("✅ User chose to restart later - quitting app")
            NSApplication.shared.terminate(nil)
        }
    }
    
    private func showInstallationError() {
        let alert = NSAlert()
        alert.messageText = L("setup.installation.error")
        alert.informativeText = L("setup.installation.error.message")
        alert.addButton(withTitle: L("setup.installation.error.retry"))
        alert.addButton(withTitle: L("setup.installation.error.cancel"))
        alert.alertStyle = .warning
        
        let response = alert.runModal()
        
        if response == .alertFirstButtonReturn {
            startInstallationProcess()
        } else {
            NSLog("❌ User cancelled after installation error")
            NSApplication.shared.terminate(nil)
        }
    }
    
    private func enableLaunchAtLogin() {
        NSLog("🔧 Enabling launch at login...")
        
        if #available(macOS 13.0, *) {
            do {
                try SMAppService.mainApp.register()
                NSLog("✅ Launch at login enabled")
            } catch {
                NSLog("❌ Failed to enable launch at login: \(error)")
            }
        } else {
            // Fallback pour macOS plus anciens
            let bundleIdentifier = Bundle.main.bundleIdentifier ?? ""
            SMLoginItemSetEnabled(bundleIdentifier as CFString, true)
            NSLog("✅ Launch at login enabled (legacy)")
        }
    }
    
    private func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return false
        }
    }
    
    private func restartMac() {
        NSLog("🔄 Restarting Mac...")
        
        let script = """
        do shell script "sudo shutdown -r now" with administrator privileges
        """
        
        let appleScript = NSAppleScript(source: script)
        appleScript?.executeAndReturnError(nil)
    }
    
    private func initializeMiloApp() {
        NSLog("🎯 Initializing Milo app interface...")

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        menuBarController = MenuBarController(statusItem: statusItem!)

        // Connecter RocVADManager au MiloConnectionManager pour que l'IP résolue
        // soit utilisée pour configurer le device roc-vad
        menuBarController?.connectionManager.rocVADManager = rocVADManager

        NSLog("✅ Milo Mac ready")
    }
    
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
