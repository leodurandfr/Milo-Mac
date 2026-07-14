import AppKit
import Foundation

/// Valeur de `kAXTrustedCheckOptionPrompt` (vérifiée : c'est bien cette chaîne).
///
/// La constante du SDK est importée depuis ApplicationServices comme une **`var` globale**
/// — comme toutes les `CFString` globales du C. La *lire* revient donc, pour le compilateur,
/// à lire un état mutable partagé, et aucune annotation posée de notre côté n'y change quoi
/// que ce soit : c'est la déclaration importée qui est en cause. On recopie donc sa valeur,
/// qui est une simple clé de dictionnaire, stable par ABI.
private let axTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

/// Raccourci clavier de volume (Option droite + flèches).
///
/// Main-thread-only, et vérifié. Ses rappels viennent de trois sources hors du système
/// de types Swift — un tap CGEvent, un moniteur global NSEvent, des Timers — mais toutes
/// arrivent **sur le main thread** : la source du tap est installée sur la run loop
/// principale (`setupEventTap`), les moniteurs NSEvent sont livrés par AppKit sur le main
/// thread, et les Timers sont posés sur la run loop principale. D'où les
/// `MainActor.assumeIsolated` : ils affirment au compilateur ce qu'un pointeur de
/// fonction C ne peut pas lui dire.
@MainActor
final class GlobalHotkeyManager {
    // MARK: - Dependencies
    private weak var connectionManager: MiloConnectionManager?
    private weak var store: MiloStore?

    // MARK: - State
    private(set) var isMonitoring = false
    private(set) var volumeHUD: VolumeHUD?
    private(set) var isActivelyAdjusting = false

    // MARK: - Repeat Logic
    private var repeatTimer: Timer?
    private var permissionTimer: Timer?
    private var currentRepeatDirection: String?
    private var repeatStartTime: Date?
    private var localVolumeDb: Double = 0
    private var limitMinDb: Double = VolumeDefaults.limitMinDb
    private var limitMaxDb: Double = VolumeDefaults.limitMaxDb
    private var isSendingVolume = false
    private var hasPendingSend = false
    private var lastSentVolumeDb: Double = 0

    // MARK: - Event Monitoring
    private var flagsChangedMonitor: Any?
    private var eventTap: CFMachPort?

    // MARK: - Key State
    private var isRightOptionPressed = false
    private var isUpArrowPressed = false
    private var isDownArrowPressed = false

    // MARK: - Constants
    private let repeatInterval: TimeInterval = 0.03  // 30ms tick for smooth acceleration
    private let upArrowKeyCode: UInt16 = 126
    private let downArrowKeyCode: UInt16 = 125
    private let rightOptionMask: UInt = 0x40
    private let defaultVolumeDeltaDb: Double = 3.0  // 3 dB par appui simple

    // MARK: - Volume Delta (en dB)
    /// Pas du raccourci clavier — réglage local (1 à 6 dB), persisté dans
    /// UserDefaults. Sans rapport avec le step_mobile_db du backend.
    var volumeDeltaDb: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: DefaultsKey.hotkeyVolumeDeltaDb)
            return saved == 0 ? defaultVolumeDeltaDb : saved
        }
        set {
            UserDefaults.standard.set(max(1.0, min(6.0, newValue)), forKey: DefaultsKey.hotkeyVolumeDeltaDb)
        }
    }

    /// Calcul du delta progressif basé sur la durée de maintien
    private func currentDelta(direction: Double) -> Double {
        guard let start = repeatStartTime else { return volumeDeltaDb * direction }
        let elapsed = Date().timeIntervalSince(start)
        // Accélération : 1x → 4x sur 2 secondes
        let multiplier = 1.0 + min(elapsed / 2.0, 1.0) * 3.0
        return volumeDeltaDb * multiplier * direction * repeatInterval / 0.08
    }

    // MARK: - Initialization
    init(connectionManager: MiloConnectionManager, store: MiloStore) {
        self.connectionManager = connectionManager
        self.store = store
        self.volumeHUD = VolumeHUD()
    }

    isolated deinit {
        stopCurrentRepeat()
        removeEventMonitors()
        permissionTimer?.invalidate()
    }

    // MARK: - Public Interface
    func startMonitoring() {
        guard AXIsProcessTrusted() else {
            requestAccessibilityPermissions()
            return
        }

        isMonitoring = true
        setupEventMonitoring()
        setupEventTap()
    }

    func stopMonitoring() {
        stopCurrentRepeat()
        isMonitoring = false
        removeEventMonitors()
        permissionTimer?.invalidate()
        permissionTimer = nil
    }

    // MARK: - Event Monitor Setup
    private func setupEventMonitoring() {
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }

        // Livré par AppKit sur le main thread.
        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleFlagsChanged(event) }
        }
    }

    private func setupEventTap() {
        cleanupEventTap()

        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self = self, self.isMonitoring else { return }
                    self.setupEventTap()
                }
            }
            return
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            // Pointeur de fonction C : il ne capture rien, et le compilateur ne peut rien
            // savoir de son isolation. La source du tap étant installée juste en dessous
            // sur la run loop PRINCIPALE, ce rappel arrive sur le main thread — d'où
            // l'`assumeIsolated`. Seul un Bool le traverse : `Unmanaged<CGEvent>` n'est pas
            // Sendable, et `assumeIsolated` n'accepte de rendre que du Sendable.
            callback: { (_, type, event, refcon) -> Unmanaged<CGEvent>? in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon).takeUnretainedValue()
                let intercept = MainActor.assumeIsolated {
                    manager.handleCGEvent(type: type, event: event)
                }
                return intercept ? nil : Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        self.eventTap = eventTap

        // `CFRunLoopGetCurrent()` — on est sur le main thread (la classe est @MainActor) :
        // c'est bien la run loop principale, ce dont dépend l'`assumeIsolated` ci-dessus.
        let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
    }

    private func cleanupEventTap() {
        if let eventTap = eventTap {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
            self.eventTap = nil
        }
    }

    private func removeEventMonitors() {
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }
        cleanupEventTap()
    }

    // MARK: - Event Handling
    /// Renvoie `true` quand l'événement doit être **intercepté** (avalé, pas propagé).
    private func handleCGEvent(type: CGEventType, event: CGEvent) -> Bool {
        // Re-enable tap if OS disabled it (timeout or slow processing)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            stopCurrentRepeat()
            return false
        }

        guard isMonitoring else { return false }

        // Handled by the CGEvent tap, whose run loop source is installed in .commonModes
        // (see setup): the hotkey keeps working while the run loop is in tracking mode —
        // e.g. while the user drags the panel's volume slider.
        if type == .flagsChanged {
            let rawFlags = UInt(event.flags.rawValue)
            let wasRightOptionPressed = isRightOptionPressed
            isRightOptionPressed = (rawFlags & rightOptionMask) != 0

            if wasRightOptionPressed && !isRightOptionPressed {
                stopCurrentRepeat()
            }
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == upArrowKeyCode || keyCode == downArrowKeyCode else { return false }

        if type == .keyDown {
            handleArrowKeyDown(keyCode: keyCode)
        } else if type == .keyUp {
            handleArrowKeyUp(keyCode: keyCode)
        }

        return isRightOptionPressed
    }

    private func handleArrowKeyDown(keyCode: UInt16) {
        switch keyCode {
        case upArrowKeyCode:
            isUpArrowPressed = true
            checkForVolumeAction(direction: "up")

        case downArrowKeyCode:
            isDownArrowPressed = true
            checkForVolumeAction(direction: "down")

        default:
            break
        }
    }

    private func handleArrowKeyUp(keyCode: UInt16) {
        switch keyCode {
        case upArrowKeyCode:
            isUpArrowPressed = false
            if currentRepeatDirection == "up" {
                stopCurrentRepeat()
            }

        case downArrowKeyCode:
            isDownArrowPressed = false
            if currentRepeatDirection == "down" {
                stopCurrentRepeat()
            }

        default:
            break
        }
    }

    private func handleFlagsChanged(_ event: NSEvent) {
        guard isMonitoring else { return }

        let eventFlags = UInt(event.modifierFlags.rawValue)
        let wasRightOptionPressed = isRightOptionPressed
        isRightOptionPressed = (eventFlags & rightOptionMask) != 0

        if wasRightOptionPressed && !isRightOptionPressed {
            stopCurrentRepeat()
        }
    }

    // MARK: - Volume Actions
    private func checkForVolumeAction(direction: String) {
        guard isRightOptionPressed else { return }

        guard let connectionManager = connectionManager,
              connectionManager.isConnected,
              connectionManager.apiService != nil else {
            NSSound.beep()
            return
        }

        if let currentDir = currentRepeatDirection, currentDir != direction {
            stopCurrentRepeat()
        }

        guard currentRepeatDirection == nil else { return }

        // Sync volume from server when starting a new hotkey sequence.
        // Only skip sync during an active hotkey hold (localVolumeDb is more
        // accurate than the lagging server echo). If HUD is visible from an
        // external change, we still resync to pick up the current value.
        let isNewSequence = !isActivelyAdjusting
        if let volume = store?.volume {
            if isNewSequence {
                localVolumeDb = volume.volumeDb
                lastSentVolumeDb = volume.volumeDb
            }
            limitMinDb = volume.limitMinDb
            limitMaxDb = volume.limitMaxDb
        }

        if isNewSequence {
            refreshVolumeLimitsInBackground()
        }

        // First press: single step (animated)
        isActivelyAdjusting = true
        volumeHUD?.updateLimits(minDb: limitMinDb, maxDb: limitMaxDb)
        let sign: Double = direction == "up" ? 1.0 : -1.0
        applyLocalDelta(volumeDeltaDb * sign, animationDuration: 0.25)
        sendVolumeToDevice()

        // Start repeat after initial delay
        currentRepeatDirection = direction
        let delayTimer = Timer(timeInterval: 0.3, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.startContinuousRepeat() }
        }
        RunLoop.current.add(delayTimer, forMode: .common)
        repeatTimer = delayTimer
    }

    private func startContinuousRepeat() {
        guard currentRepeatDirection != nil else { return }
        repeatStartTime = Date()
        let timer = Timer(timeInterval: repeatInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.repeatTick() }
        }
        RunLoop.current.add(timer, forMode: .common)
        repeatTimer = timer
    }

    private func repeatTick() {
        guard let direction = currentRepeatDirection else { return }

        let shouldContinue = isRightOptionPressed &&
                           ((direction == "up" && isUpArrowPressed) ||
                            (direction == "down" && isDownArrowPressed))

        guard shouldContinue else {
            stopCurrentRepeat()
            return
        }

        let sign: Double = direction == "up" ? 1.0 : -1.0
        let delta = currentDelta(direction: sign)
        applyLocalDelta(delta)
        sendVolumeToDevice()
    }

    private func applyLocalDelta(_ delta: Double, animationDuration: TimeInterval = 0.05) {
        localVolumeDb = min(limitMaxDb, max(limitMinDb, localVolumeDb + delta))
        volumeHUD?.show(volumeDb: localVolumeDb)
        NotificationCenter.default.post(
            name: .volumeChangedViaHotkey,
            object: VolumeStatus(
                volumeDb: localVolumeDb, multiroomEnabled: false,
                dspAvailable: false, limitMinDb: limitMinDb,
                limitMaxDb: limitMaxDb
            ),
            userInfo: ["animationDuration": animationDuration]
        )
    }

    private func sendVolumeToDevice() {
        guard !isSendingVolume,
              let apiService = connectionManager?.apiService else {
            hasPendingSend = true
            return
        }

        let targetDb = localVolumeDb
        let delta = targetDb - lastSentVolumeDb
        guard abs(delta) > 0.01 else { return }

        lastSentVolumeDb = targetDb
        isSendingVolume = true

        // La classe est main-isolée : cette Task hérite du main actor. Seul l'`await`
        // part sur le réseau — le reste du corps y revient tout seul, sans MainActor.run.
        Task {
            do {
                try await apiService.adjustVolumeDb(delta)
            } catch {
                // Ignore errors during rapid changes
            }
            isSendingVolume = false
            if hasPendingSend {
                hasPendingSend = false
                sendVolumeToDevice()
            }
        }
    }

    private func refreshVolumeLimitsInBackground() {
        guard let apiService = connectionManager?.apiService else { return }

        Task {
            do {
                let volumeStatus = try await apiService.getVolumeStatus()
                limitMinDb = volumeStatus.limitMinDb
                limitMaxDb = volumeStatus.limitMaxDb
                volumeHUD?.updateLimits(minDb: volumeStatus.limitMinDb, maxDb: volumeStatus.limitMaxDb)
                store?.updateVolumeStatus(volumeStatus)
            } catch {
                // Silencieux - on garde les valeurs en cache
            }
        }
    }

    private func stopCurrentRepeat() {
        repeatTimer?.invalidate()
        repeatTimer = nil
        let wasRepeating = currentRepeatDirection != nil
        currentRepeatDirection = nil
        repeatStartTime = nil
        isActivelyAdjusting = false
        // Only flush final volume if a volume action was actually in progress
        guard wasRepeating else { return }
        if isSendingVolume {
            hasPendingSend = true
        } else {
            sendVolumeToDevice()
        }
    }

    // MARK: - Permissions
    private func requestAccessibilityPermissions() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        let options: CFDictionary = [axTrustedCheckOptionPrompt: true] as CFDictionary
        let result = AXIsProcessTrustedWithOptions(options)

        if result {
            isMonitoring = true
            setupEventMonitoring()
            setupEventTap()
        } else {
            startPermissionMonitoring()
        }
    }

    private func startPermissionMonitoring() {
        // Un seul timer de poll, stocké et invalidé : startMonitoring() est
        // rappelé à chaque reconnexion — sans cela, chaque cycle empilait un
        // timer répétitif perpétuel de plus.
        permissionTimer?.invalidate()
        // Le timer est invalidé hors de `assumeIsolated` (Timer n'est pas Sendable, et
        // celle-ci n'accepte de rendre que du Sendable) : seul un Bool la traverse.
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            let done = MainActor.assumeIsolated { () -> Bool in
                guard AXIsProcessTrusted() else { return false }
                guard let self else { return true }
                self.permissionTimer = nil
                self.isMonitoring = true
                self.setupEventMonitoring()
                self.setupEventTap()
                return true
            }
            if done { timer.invalidate() }
        }
    }
}
