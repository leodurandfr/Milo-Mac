import SwiftUI
import ServiceManagement

// MARK: - Shared identifiers

/// UserDefaults keys shared across files — a single definition, so a typo cannot silently
/// split the persisted state.
enum DefaultsKey {
    static let showVolumeHUDOnAllChanges = "ShowVolumeHUDOnAllChanges"
    static let hotkeyVolumeDeltaDb = "HotkeyVolumeDeltaDb"

    /// Whether the volume shortcuts are wanted. Registered to `true` (see
    /// `registerFactoryDefaults`), so they are on out of the box; only an explicit
    /// switch-off in Settings ever writes `false`.
    ///
    /// Wanting them and being able to run them are two different things: the shortcuts
    /// need the Accessibility permission, which this preference says nothing about.
    static let hotkeysEnabled = "HotkeysEnabled"

    /// Set once the system Accessibility prompt has been posted. TCC only ever shows that
    /// alert once per app, so this flag is what keeps us from silently re-asking for
    /// something that can no longer be granted that way — after it, the only route left is
    /// the button in Settings that opens the System Settings pane.
    static let didRequestAccessibilityPermission = "DidRequestAccessibilityPermission"
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
        //
        // `Settings` is only here because an App needs a scene, and this is the one that
        // presents nothing. Declaring it does add a "Settings…" (⌘,) item to the app menu,
        // wired to this empty view — harmless while the app is `.accessory`, since no menu
        // bar is drawn, but `SettingsWindowPresenter` now switches to `.regular` for the
        // lifetime of the real Settings window. The item would then be reachable, and open
        // a blank window beside it. Hence the empty replacement.
        Settings { EmptyView() }
            .commands {
                CommandGroup(replacing: .appSettings) { }
            }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: MiloStore?
    private var menuBarShell: MenuBarShell?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.registerFactoryDefaults()

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

    /// The values a fresh install starts from.
    ///
    /// `register(defaults:)` rather than a `?? true` at each read site: the registration
    /// domain is only consulted when nothing has been written, so a user who switched the
    /// shortcuts off keeps them off, and there is a single place stating what "by default"
    /// means.
    private static func registerFactoryDefaults() {
        UserDefaults.standard.register(defaults: [
            DefaultsKey.hotkeysEnabled: true
        ])
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
