import AppKit
import SwiftUI

/// Controller for the unified Settings window (hosts SwiftUI SettingsView)
class SettingsWindowController: NSObject {
    static let shared = SettingsWindowController()

    override private init() {
        super.init()
    }

    // MARK: - Dependencies
    private weak var hotkeyManager: GlobalHotkeyManager?
    private weak var rocVADManager: RocVADManager?

    // MARK: - Window
    private var window: NSWindow?
    private var hostingController: NSViewController?

    // MARK: - Public Interface

    /// Configure the settings window with required dependencies
    func configure(hotkeyManager: GlobalHotkeyManager?, rocVADManager: RocVADManager?) {
        self.hotkeyManager = hotkeyManager
        self.rocVADManager = rocVADManager
    }

    /// Show the settings window
    func showWindow() {
        if let existingWindow = window {
            existingWindow.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        guard #available(macOS 14.0, *) else { return }
        createWindow()

        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Close the settings window
    func closeWindow() {
        window?.close()
        window = nil
        hostingController = nil
    }

    // MARK: - Window Creation

    @available(macOS 14.0, *)
    private func createWindow() {
        let viewModel = SettingsViewModel(hotkeyManager: hotkeyManager, rocVADManager: rocVADManager)
        let settingsView = SettingsView(vm: viewModel)
        let hosting = NSHostingController(rootView: settingsView)
        hosting.sizingOptions = [.preferredContentSize]

        let window = NSWindow(contentViewController: hosting)
        window.title = L("settings.title")
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        window.delegate = self

        viewModel.onNeedsResize = { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now()) {
                self?.resizeWindowToFit()
            }
        }

        self.window = window
        self.hostingController = hosting
    }

    private func resizeWindowToFit() {
        guard let window, let hosting = hostingController else { return }
        let fittingSize = hosting.view.fittingSize
        var frame = window.frame
        let titleBarHeight = frame.height - window.contentLayoutRect.height
        let newHeight = fittingSize.height + titleBarHeight
        frame.origin.y -= (newHeight - frame.height)
        frame.size.height = newHeight
        window.setFrame(frame, display: true, animate: true)
    }
}

// MARK: - NSWindowDelegate

extension SettingsWindowController: NSWindowDelegate {
    func windowWillClose(_ notification: Notification) {
        window = nil
        hostingController = nil
    }
}
