import AppKit
import SwiftUI

/// Presents the Settings window, which hosts the SwiftUI `SettingsView`.
///
/// Like MenuBarShell, this is a minimal AppKit shell around a 100% SwiftUI view.
/// SwiftUI's `Settings` scene is not usable here: `SettingsLink` only opens from the
/// App's scene tree, and our panel lives in an NSPanel presented by an NSStatusItem —
/// outside that tree.
@MainActor
enum SettingsWindowPresenter {
    private static var controller: SettingsWindowController?

    static func show(store: MiloStore) {
        if let controller {
            controller.showWindow()
            return
        }

        let created = SettingsWindowController(store: store)
        controller = created
        created.onClose = { controller = nil }
        created.showWindow()
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private let store: MiloStore
    private var window: NSWindow?
    private var hostingController: NSHostingController<SettingsView>?

    var onClose: (() -> Void)?

    init(store: MiloStore) {
        self.store = store
        super.init()
    }

    func showWindow() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let viewModel = SettingsViewModel(
            hotkeyManager: store.hotkeyManager,
            rocVADManager: store.rocVADManager
        )
        let hosting = NSHostingController(rootView: SettingsView(vm: viewModel, store: store))

        // ⚠️ Definitely NOT `.preferredContentSize`: AppKit then reads `preferredContentSize`
        // from `-[NSViewController updateViewConstraints]`, hence DURING the window's constraint
        // update pass. SwiftUI measures, and that measurement re-invalidates the constraints —
        // the pass never converges and AppKit throws, after N rounds:
        // "The window has been marked as needing another Update Constraints in Window pass,
        // but it has already had more Update Constraints in Window passes than there are views
        // in the window." (a crash when opening Settings from the panel).
        //
        // `.intrinsicContentSize` gives the same measurement (fittingSize) without that read
        // during the pass. The window itself is sized here and then by `resizeWindowToFit()` —
        // which it already did for the "Mac Audio" section's expansion.
        hosting.sizingOptions = [.intrinsicContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)

        // The "Mac Audio" section expands and collapses: the window has to follow.
        viewModel.onNeedsResize = { [weak self] in
            DispatchQueue.main.async { self?.resizeWindowToFit() }
        }

        self.window = window
        self.hostingController = hosting

        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func resizeWindowToFit() {
        guard let window, let hostingController else { return }
        // Measure the new content right away: without this, `fittingSize` would still return
        // the height from BEFORE the expansion, and the window would resize one round too late.
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        var frame = window.frame
        let titleBarHeight = frame.height - window.contentLayoutRect.height
        let newHeight = fittingSize.height + titleBarHeight
        // Anchor by the top: otherwise the window "walks down" on every expansion.
        frame.origin.y -= (newHeight - frame.height)
        frame.size.height = newHeight
        // `animate: false`: the content itself appears instantly (the Section already has
        // `.animation(nil, …)`). Animating the window would make it lag ~0.2 s behind its
        // content — that lag is what read as "slow to open".
        window.setFrame(frame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
        onClose?()
    }
}
