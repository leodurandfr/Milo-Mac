import AppKit
import Foundation

class GlobalHotkeyManager {
    // MARK: - Dependencies
    private weak var connectionManager: MiloConnectionManager?
    private weak var menuController: MenuBarController?

    // MARK: - State
    private var isMonitoring = false
    private(set) var volumeHUD: VolumeHUD?
    private(set) var isActivelyAdjusting = false

    // MARK: - Repeat Logic
    private var repeatTimer: Timer?
    private var currentRepeatDirection: String?
    private var repeatStartTime: Date?
    private var localVolumeDb: Double = 0
    private var limitMinDb: Double = -80
    private var limitMaxDb: Double = -21
    private var isSendingVolume = false
    private var hasPendingSend = false

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
    private let volumeDeltaDbKey = "HotkeyVolumeDeltaDb"
    private let defaultVolumeDeltaDb: Double = 3.0  // 3 dB par appui simple

    // MARK: - Volume Delta (en dB)
    private var volumeDeltaDb: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: volumeDeltaDbKey)
            return saved == 0 ? defaultVolumeDeltaDb : saved
        }
        set {
            UserDefaults.standard.set(newValue, forKey: volumeDeltaDbKey)
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
    init(connectionManager: MiloConnectionManager, menuController: MenuBarController) {
        self.connectionManager = connectionManager
        self.menuController = menuController
        self.volumeHUD = VolumeHUD()
    }

    deinit {
        stopCurrentRepeat()
        removeEventMonitors()
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
    }

    func isCurrentlyMonitoring() -> Bool {
        return isMonitoring
    }

    func hasAccessibilityPermissions() -> Bool {
        return AXIsProcessTrusted()
    }

    func recheckPermissions() {
        if AXIsProcessTrusted() {
            if !isMonitoring {
                isMonitoring = true
            }
            setupEventMonitoring()
            setupEventTap()
        }
    }

    func getVolumeDeltaDb() -> Double {
        return volumeDeltaDb
    }

    func setVolumeDeltaDb(_ deltaDb: Double) {
        volumeDeltaDb = max(1.0, min(6.0, deltaDb))  // 1 à 6 dB
    }

    // MARK: - Event Monitor Setup
    private func setupEventMonitoring() {
        if let monitor = flagsChangedMonitor {
            NSEvent.removeMonitor(monitor)
            flagsChangedMonitor = nil
        }

        flagsChangedMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { [weak self] event in
            self?.handleFlagsChanged(event)
        }
    }

    private func setupEventTap() {
        cleanupEventTap()

        guard AXIsProcessTrusted() else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                guard let self = self, self.isMonitoring else { return }
                self.setupEventTap()
            }
            return
        }

        let eventMask = (1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue)

        guard let eventTap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(eventMask),
            callback: { (proxy, type, event, refcon) -> Unmanaged<CGEvent>? in
                let manager = Unmanaged<GlobalHotkeyManager>.fromOpaque(refcon!).takeUnretainedValue()
                return manager.handleCGEvent(proxy: proxy, type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return
        }

        self.eventTap = eventTap

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
    private func handleCGEvent(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-enable tap if OS disabled it (timeout or slow processing)
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let eventTap = eventTap {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            stopCurrentRepeat()
            return Unmanaged.passUnretained(event)
        }

        guard isMonitoring else {
            return Unmanaged.passUnretained(event)
        }

        // Handle flags changed via CGEvent tap (works even during NSMenu tracking)
        if type == .flagsChanged {
            let rawFlags = UInt(event.flags.rawValue)
            let wasRightOptionPressed = isRightOptionPressed
            isRightOptionPressed = (rawFlags & rightOptionMask) != 0

            if wasRightOptionPressed && !isRightOptionPressed {
                stopCurrentRepeat()
            }
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        if keyCode == upArrowKeyCode || keyCode == downArrowKeyCode {
            if type == .keyDown {
                handleArrowKeyDown(keyCode: keyCode)
            } else if type == .keyUp {
                handleArrowKeyUp(keyCode: keyCode)
            }

            if isRightOptionPressed {
                return nil // Intercept event
            }
        }

        return Unmanaged.passUnretained(event)
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
              connectionManager.isCurrentlyConnected(),
              connectionManager.getAPIService() != nil else {
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
        if let volume = menuController?.currentVolume {
            if isNewSequence {
                localVolumeDb = volume.volumeDb
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
            self?.startContinuousRepeat()
        }
        RunLoop.current.add(delayTimer, forMode: .common)
        repeatTimer = delayTimer
    }

    private func startContinuousRepeat() {
        guard currentRepeatDirection != nil else { return }
        repeatStartTime = Date()
        let timer = Timer(timeInterval: repeatInterval, repeats: true) { [weak self] _ in
            self?.repeatTick()
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
            name: NSNotification.Name("VolumeChangedViaHotkey"),
            object: VolumeStatus(
                volumeDb: localVolumeDb, multiroomEnabled: false,
                dspAvailable: false, limitMinDb: limitMinDb,
                limitMaxDb: limitMaxDb, stepMobileDb: volumeDeltaDb
            ),
            userInfo: ["animationDuration": animationDuration]
        )
    }

    private func sendVolumeToDevice() {
        guard !isSendingVolume,
              let apiService = connectionManager?.getAPIService() else {
            hasPendingSend = true
            return
        }

        let targetDb = localVolumeDb
        isSendingVolume = true

        Task {
            do {
                try await apiService.setVolumeDb(targetDb)
            } catch {
                // Ignore errors during rapid changes
            }
            DispatchQueue.main.async {
                self.isSendingVolume = false
                if self.hasPendingSend {
                    self.hasPendingSend = false
                    self.sendVolumeToDevice()
                }
            }
        }
    }

    private func refreshVolumeLimitsInBackground() {
        guard let apiService = connectionManager?.getAPIService() else { return }

        Task {
            do {
                let volumeStatus = try await apiService.getVolumeStatus()
                await MainActor.run {
                    self.limitMinDb = volumeStatus.limitMinDb
                    self.limitMaxDb = volumeStatus.limitMaxDb
                    self.volumeHUD?.updateLimits(minDb: volumeStatus.limitMinDb, maxDb: volumeStatus.limitMaxDb)
                    self.menuController?.updateVolumeStatus(volumeStatus)
                }
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

        let options: CFDictionary = [kAXTrustedCheckOptionPrompt.takeRetainedValue() as String: true] as CFDictionary
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
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if AXIsProcessTrusted() {
                timer.invalidate()
                self?.isMonitoring = true
                self?.setupEventMonitoring()
                self?.setupEventTap()
            }
        }
    }
}
