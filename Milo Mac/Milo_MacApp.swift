import SwiftUI
import ServiceManagement

// MARK: - Shared identifiers

/// UserDefaults keys shared across files — a single definition, so a typo cannot silently
/// split the persisted state.
enum DefaultsKey {
    static let showVolumeHUDOnAllChanges = "ShowVolumeHUDOnAllChanges"
    static let hotkeyVolumeDeltaDb = "HotkeyVolumeDeltaDb"
}

extension Notification.Name {
    /// Posted by GlobalHotkeyManager on every local volume adjustment, observed by
    /// MiloStore to keep the slider and the cache in sync.
    static let volumeChangedViaHotkey = Notification.Name("VolumeChangedViaHotkey")
}

@main
struct Milo_MacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // The app lives entirely in the menu bar: there is no scene to present.
        // The panel is an NSPanel (MenuBarShell) and Settings an NSWindow
        // (SettingsWindowPresenter), both hosting SwiftUI views.
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

        // The menu-bar icon appears immediately, before any check runs.
        // Milō is fully usable without roc-vad — only the "Mac" source depends on
        // it — so nothing justifies delaying the interface or, worse, refusing to
        // start. roc-vad is a state, not a toll.
        let store = MiloStore()
        self.store = store
        self.menuBarShell = MenuBarShell(store: store)

        store.attachRocVAD(RocVADManager())
        store.start()

        // Driver setup in the background, never blocking the UI.
        store.prepareRocVADIfInstalled()

        NSLog("✅ Milō Mac ready")
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
