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

        // ⚠️ Surtout PAS `.preferredContentSize` : AppKit lit alors `preferredContentSize`
        // depuis `-[NSViewController updateViewConstraints]`, donc PENDANT la passe de mise à
        // jour des contraintes de la fenêtre. SwiftUI mesure, et cette mesure ré-invalide les
        // contraintes — la passe ne converge jamais et AppKit lève, au bout de N tours :
        // « The window has been marked as needing another Update Constraints in Window pass,
        // but it has already had more Update Constraints in Window passes than there are views
        // in the window. » (crash à l'ouverture des Réglages depuis le panneau).
        //
        // `.intrinsicContentSize` donne la même mesure (fittingSize) sans cette lecture pendant
        // la passe. La fenêtre, elle, est dimensionnée ici puis par `resizeWindowToFit()` —
        // ce qu'elle faisait déjà pour le dépliage de la section « Audio Mac ».
        hosting.sizingOptions = [.intrinsicContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.setContentSize(hosting.view.fittingSize)

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
        // Mesurer le nouveau contenu tout de suite : sans ça, `fittingSize` renverrait encore
        // la hauteur d'AVANT le dépliage, et la fenêtre se redimensionnerait un tour trop tard.
        hostingController.view.layoutSubtreeIfNeeded()
        let fittingSize = hostingController.view.fittingSize
        var frame = window.frame
        let titleBarHeight = frame.height - window.contentLayoutRect.height
        let newHeight = fittingSize.height + titleBarHeight
        // Ancrer par le haut : sinon la fenêtre « descend » à chaque dépliage.
        frame.origin.y -= (newHeight - frame.height)
        frame.size.height = newHeight
        // `animate: false` : le contenu, lui, apparaît instantanément (la Section a déjà
        // `.animation(nil, …)`). Animer la fenêtre la ferait traîner ~0,2 s derrière son
        // contenu — c'est ce décalage qu'on lisait comme « lent à s'ouvrir ».
        window.setFrame(frame, display: true, animate: false)
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
        onClose?()
    }
}
