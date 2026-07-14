import SwiftUI
import ServiceManagement

// MARK: - Shared identifiers

/// Clés UserDefaults partagées entre fichiers — une seule définition pour qu'une faute de
/// frappe ne puisse pas scinder silencieusement l'état persisté.
enum DefaultsKey {
    static let showVolumeHUDOnAllChanges = "ShowVolumeHUDOnAllChanges"
    static let hotkeyVolumeDeltaDb = "HotkeyVolumeDeltaDb"
}

extension Notification.Name {
    /// Posté par GlobalHotkeyManager à chaque ajustement local du volume, observé par
    /// MiloStore pour synchroniser le slider et le cache.
    static let volumeChangedViaHotkey = Notification.Name("VolumeChangedViaHotkey")
}

@main
struct Milo_MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // L'app vit entièrement dans la barre de menus : aucune scène à présenter.
        // Le panneau est une NSPanel (MenuBarShell) et les Réglages une NSWindow
        // (SettingsWindowPresenter), tous deux hébergeant des vues SwiftUI.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MiloStore?
    private var menuBarShell: MenuBarShell?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        if NSApp.activationPolicy() != .accessory {
            NSApp.setActivationPolicy(.prohibited)
            NSApp.setActivationPolicy(.accessory)
        }

        NSLog("🚀 Milō Mac starting...")

        // L'icône de barre de menus apparaît immédiatement, avant toute vérification.
        // Milō est pleinement utilisable sans roc-vad — seule la source « Mac » en
        // dépend — donc rien ne justifie de retarder l'interface ou, pire, de refuser
        // de démarrer. roc-vad est un état, pas un péage.
        let store = MiloStore()
        self.store = store
        self.menuBarShell = MenuBarShell(store: store)

        store.attachRocVAD(RocVADManager())
        store.start()

        // Configuration du driver en arrière-plan, sans jamais bloquer l'UI.
        store.prepareRocVADIfInstalled()

        NSLog("✅ Milō Mac ready")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
