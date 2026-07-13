import AppKit
import SwiftUI

/// Présente la fenêtre de Réglages, qui héberge la vue SwiftUI `SettingsView`.
///
/// Comme MenuBarShell, c'est une coquille AppKit minimale autour d'une vue 100 % SwiftUI.
/// La scène `Settings` de SwiftUI n'est pas utilisable ici : `SettingsLink` ne s'ouvre
/// que depuis l'arbre de scènes de l'App, or notre panneau vit dans un NSPopover présenté
/// par un NSStatusItem — hors de cet arbre.
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
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self

        // La section « Audio Mac » se déplie/replie : la fenêtre doit suivre.
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
        let fittingSize = hostingController.view.fittingSize
        var frame = window.frame
        let titleBarHeight = frame.height - window.contentLayoutRect.height
        let newHeight = fittingSize.height + titleBarHeight
        // Ancrer par le haut : sinon la fenêtre « descend » à chaque dépliage.
        frame.origin.y -= (newHeight - frame.height)
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: true)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
        onClose?()
    }
}
