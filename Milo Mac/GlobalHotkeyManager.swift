import AppKit
import Foundation

/// The value of `kAXTrustedCheckOptionPrompt` (verified: this really is the string).
///
/// The SDK constant is imported from ApplicationServices as a **global `var`** — like every
/// global `CFString` from C. *Reading* it therefore amounts, as far as the compiler is
/// concerned, to reading shared mutable state, and no annotation on our side changes that:
/// the imported declaration is what is at fault. So we copy its value, which is a plain
/// dictionary key, stable by ABI.
private let axTrustedCheckOptionPrompt = "AXTrustedCheckOptionPrompt"

/// Volume keyboard shortcut (right Option + arrows).
///
/// Main-thread-only, and checked. Its callbacks come from three sources outside Swift's
/// type system — a CGEvent tap, a global NSEvent monitor, Timers — but all of them arrive
/// **on the main thread**: the tap's source is installed on the main run loop
/// (`setupEventTap`), the NSEvent monitors are delivered by AppKit on the main thread, and
/// the Timers are scheduled on the main run loop. Hence the `MainActor.assumeIsolated`
/// calls: they assert to the compiler what a C function pointer cannot tell it.
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

    /// Holding a slider icon (mouse), as opposed to holding an arrow (keyboard) — both
    /// drive the same `repeatTick`, but their stop condition differs: there is no key to
    /// watch here, just this boolean.
    private var isButtonHeld = false

    // MARK: - Constants
    private let repeatInterval: TimeInterval = 0.03  // 30ms tick for smooth acceleration
    private let upArrowKeyCode: UInt16 = 126
    private let downArrowKeyCode: UInt16 = 125
    private let rightOptionMask: UInt = 0x40
    private let defaultVolumeDeltaDb: Double = 3.0  // 3 dB per single press

    // MARK: - Volume Delta (in dB)
    /// Keyboard shortcut step — a local setting (1 to 6 dB), persisted in
    /// UserDefaults. Unrelated to the backend's step_mobile_db.
    var volumeDeltaDb: Double {
        get {
            let saved = UserDefaults.standard.double(forKey: DefaultsKey.hotkeyVolumeDeltaDb)
            return saved == 0 ? defaultVolumeDeltaDb : saved
        }
        set {
            UserDefaults.standard.set(max(1.0, min(6.0, newValue)), forKey: DefaultsKey.hotkeyVolumeDeltaDb)
        }
    }

    /// Computes the progressive delta from how long the key has been held
    private func currentDelta(direction: Double) -> Double {
        guard let start = repeatStartTime else { return volumeDeltaDb * direction }
        let elapsed = Date().timeIntervalSince(start)
        // Acceleration: 1x → 4x over 2 seconds
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

        // Delivered by AppKit on the main thread.
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
            // A C function pointer: it captures nothing, and the compiler can know nothing
            // about its isolation. Since the tap's source is installed just below on the
            // MAIN run loop, this callback arrives on the main thread — hence the
            // `assumeIsolated`. Only a Bool crosses it: `Unmanaged<CGEvent>` is not
            // Sendable, and `assumeIsolated` only accepts returning Sendable values.
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

        // `CFRunLoopGetCurrent()` — we are on the main thread (the class is @MainActor):
        // this really is the main run loop, which the `assumeIsolated` above depends on.
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
    /// Returns `true` when the event must be **intercepted** (swallowed, not propagated).
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
        beginRepeat(direction: direction)
    }

    /// Holding a slider icon — the same path as the keyboard shortcut (`beginRepeat`),
    /// without the "right Option held" guard, which makes no sense for a mouse button:
    /// same local prediction, same acceleration, same HUD.
    func beginButtonHold(direction: String) {
        isButtonHeld = true
        beginRepeat(direction: direction)
    }

    func endButtonHold() {
        isButtonHeld = false
        stopCurrentRepeat()
    }

    private func beginRepeat(direction: String) {
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

        // No key to watch for a mouse hold: `isButtonHeld` is updated directly by
        // `beginButtonHold`/`endButtonHold`.
        let shouldContinue = isButtonHeld ||
                           (isRightOptionPressed &&
                            ((direction == "up" && isUpArrowPressed) ||
                             (direction == "down" && isDownArrowPressed)))

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
                limitMinDb: limitMinDb, limitMaxDb: limitMaxDb
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

        // The class is main-isolated: this Task inherits the main actor. Only the `await`
        // goes out to the network — the rest of the body returns on its own, no MainActor.run.
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
                // Silent — we keep the cached values
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
        isButtonHeld = false
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
        // A single poll timer, stored and invalidated: startMonitoring() is called again
        // on every reconnection — without this, each cycle stacked up one more perpetual
        // repeating timer.
        permissionTimer?.invalidate()
        // The timer is invalidated outside `assumeIsolated` (Timer is not Sendable, and
        // that call only accepts returning Sendable values): only a Bool crosses it.
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
