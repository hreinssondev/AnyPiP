import AppKit
import Carbon.HIToolbox
import Combine
import CoreMedia

struct AutoPiPAppSelection: Codable, Identifiable, Hashable, Sendable {
    let bundleIdentifier: String
    let displayName: String

    var id: String { bundleIdentifier }
}

enum ShortcutTriggerMode: String, CaseIterable, Identifiable {
    case modifierKey
    case doublePress
    case singleKey

    var id: String { rawValue }

    var title: String {
        switch self {
        case .modifierKey:
            return "With modifier"
        case .doublePress:
            return "Double press"
        case .singleKey:
            return "Single key"
        }
    }
}

@MainActor
final class AppCoordinator: ObservableObject {
    private enum SourceHideStrategy {
        case hiddenApp
        case privateAlpha
        case privateAlphaFailed(String)
        case fakeHide
    }

    private enum PiPEntryBehavior {
        case interactive
        case passiveAutomatic

        var allowsInteractiveControls: Bool {
            switch self {
            case .interactive:
                return true
            case .passiveAutomatic:
                return false
            }
        }

        var cachesRestoreSnapshot: Bool {
            switch self {
            case .interactive:
                return true
            case .passiveAutomatic:
                return true
            }
        }

        var usesSavedManualFrame: Bool {
            switch self {
            case .interactive:
                return true
            case .passiveAutomatic:
                return false
            }
        }
    }

    @Published var statusText = "Ready. Press ⌥P to create PiP from the frontmost window."
    @Published var isScreenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
    @Published var isAccessibilityTrusted = PermissionManager.isAccessibilityTrusted
    @Published var activeTargetDescription: String?
    @Published var hotkeyInput = "⌥P"
    @Published var doubleTapHotkeyInput = "⌥⎋"
    @Published var primaryDoubleTapKeyInput = "P"
    @Published var doubleTapKeyInput = "⎋"
    @Published var primarySingleKeyInput = "P"
    @Published var doubleTapSingleKeyInput = "⎋"
    @Published var primaryShortcutMode: ShortcutTriggerMode = .modifierKey
    @Published var doubleTapShortcutMode: ShortcutTriggerMode = .doublePress
    @Published var hoverSwitchEnabled = UserDefaults.standard.bool(forKey: "HoverSwitchEnabled")
    @Published private(set) var autoPiPAppSelections: [AutoPiPAppSelection] = []
    @Published private(set) var availableAutoPiPApps: [AutoPiPAppSelection] = []
    @Published private(set) var isRefreshingAutoPiPApps = false

    private var hotKey: GlobalHotKey?
    private var doubleTapActionHotKey: GlobalHotKey?
    private var currentKeyCode: UInt32 = UInt32(kVK_ANSI_P)
    private var currentModifiers: UInt32 = UInt32(optionKey)
    private var currentDoubleTapHotKeyCode: UInt32 = UInt32(kVK_Escape)
    private var currentDoubleTapHotKeyModifiers: UInt32 = UInt32(optionKey)
    private var currentPrimaryDoubleTapKeyCode: UInt16 = UInt16(kVK_ANSI_P)
    private var currentDoubleTapKeyCode: UInt16 = UInt16(kVK_Escape)
    private var currentPrimarySingleKeyCode: UInt16 = UInt16(kVK_ANSI_P)
    private var currentDoubleTapSingleKeyCode: UInt16 = UInt16(kVK_Escape)
    private var captureSession: WindowCaptureSession?
    private var pipWindowController: PiPWindowController?
    private var activeTarget: WindowTarget?
    private var sourceVisibleFrame: CGRect?
    private var sourceHideStrategy: SourceHideStrategy?
    private var hiddenApp: NSRunningApplication?
    private var isGlancing = false
    private var streamErrorObserver: NSObjectProtocol?
    private var appWillTerminateObserver: NSObjectProtocol?
    private var appActivationObserver: NSObjectProtocol?
    private var appTerminationObserver: NSObjectProtocol?
    private var globalKeyDownMonitor: Any?
    private var localKeyDownMonitor: Any?
    private let privateWindowAlphaController = PrivateWindowAlphaController()
    private let windowOrderController = WindowOrderController()
    private let shouldFallBackToFakeHideAfterPrivateAlphaFailure = false
    private var lastPrimaryDoublePressDate: Date?
    private var lastExitDoublePressDate: Date?
    private var lastDoubleTapKeyPressDate: Date?
    private var lastExitedTargetSnapshot: WindowTarget?
    private var lastExitedSourceFrameSnapshot: CGRect?
    private var lastExitedHideStrategySnapshot: SourceHideStrategy?
    private var lastExitedHoverSwitchEnabledSnapshot: Bool?
    private var isHotKeyRecordingActive = false
    private var activePiPBehavior: PiPEntryBehavior = .interactive
    private var lastObservedActivatedApp: NSRunningApplication?
    private var automaticPiPStartInFlightProcessID: pid_t?
    private var ignoreNextSourceActivationUntil: Date?

    private static let autoPiPAppSelectionsKey = "AutoPiPAppSelections"

    var doubleTapActionInstructionText: String {
        switch doubleTapShortcutMode {
        case .doublePress:
            return "\(doubleTapKeyInput) twice"
        case .modifierKey:
            return doubleTapHotkeyInput
        case .singleKey:
            return doubleTapSingleKeyInput
        }
    }

    init() {
        if let saved = UserDefaults.standard.string(forKey: "PrimaryShortcutMode"),
           let mode = ShortcutTriggerMode(rawValue: saved) {
            primaryShortcutMode = mode
        }
        if let saved = UserDefaults.standard.string(forKey: "DoubleTapShortcutMode"),
           let mode = ShortcutTriggerMode(rawValue: saved) {
            doubleTapShortcutMode = mode
        }
        if let saved = UserDefaults.standard.string(forKey: "HotkeyInput") {
            hotkeyInput = saved
            if let parsed = parseHotkey(from: saved) {
                currentKeyCode = parsed.keyCode
                currentModifiers = parsed.modifiers
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "DoubleTapHotkeyInput") {
            doubleTapHotkeyInput = saved
            if let parsed = parseHotkey(from: saved) {
                currentDoubleTapHotKeyCode = parsed.keyCode
                currentDoubleTapHotKeyModifiers = parsed.modifiers
            }
        }
        if let saved = UserDefaults.standard.string(forKey: "PrimaryDoubleTapKeyInput"),
           let keyCode = parseDoubleTapKey(from: saved) {
            currentPrimaryDoubleTapKeyCode = keyCode
            primaryDoubleTapKeyInput = keySymbol(for: keyCode)
        }
        if let saved = UserDefaults.standard.string(forKey: "DoubleTapKeyInput"),
           let keyCode = parseDoubleTapKey(from: saved) {
            currentDoubleTapKeyCode = keyCode
            doubleTapKeyInput = keySymbol(for: keyCode)
        }
        if let saved = UserDefaults.standard.string(forKey: "PrimarySingleKeyInput"),
           let keyCode = parseDoubleTapKey(from: saved) {
            currentPrimarySingleKeyCode = keyCode
            primarySingleKeyInput = keySymbol(for: keyCode)
        }
        if let saved = UserDefaults.standard.string(forKey: "DoubleTapSingleKeyInput"),
           let keyCode = parseDoubleTapKey(from: saved) {
            currentDoubleTapSingleKeyCode = keyCode
            doubleTapSingleKeyInput = keySymbol(for: keyCode)
        }
        hoverSwitchEnabled = UserDefaults.standard.object(forKey: "HoverSwitchEnabled") as? Bool ?? false
        loadAutoPiPAppSelections()
        lastObservedActivatedApp = NSWorkspace.shared.frontmostApplication
        registerHotKey()
        registerDoubleTapActionHotKey()
        streamErrorObserver = NotificationCenter.default.addObserver(
            forName: .captureStreamStoppedWithError,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let message = (notification.object as? Error)?.localizedDescription ?? "The capture stream stopped."
            Task { @MainActor in
                self?.statusText = message
                await self?.stopPiP(restoreSource: true)
            }
        }
        appWillTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            let coordinator = self
            Task { @MainActor in
                coordinator?.restoreSourceWindowBeforeTermination()
            }
        }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            Task { @MainActor in
                guard let self else { return }

                if self.isGlancing,
                   let target = self.activeTarget,
                   activatedApp.processIdentifier != target.processID {
                    self.sendBackToPiP()
                }

                if self.shouldShowSourceForManualPiPAfterSourceActivation(activatedApp) {
                    self.showSourceForManualPiPAfterSourceActivation()
                } else if self.shouldStopPiPAfterSourceActivation(activatedApp) {
                    if self.activePiPBehavior.cachesRestoreSnapshot {
                        self.cacheCurrentPiPForRestore()
                    }
                    await self.stopPiP(restoreSource: true, focusSource: true)
                }

                let previousApp = self.lastObservedActivatedApp
                self.lastObservedActivatedApp = activatedApp
                self.handleAutomaticPiPActivation(previousApp: previousApp, activatedApp: activatedApp)
            }
        }
        appTerminationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let terminatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }

            let coordinator = self
            Task { @MainActor in
                coordinator?.handleApplicationTermination(terminatedApp)
            }
        }
        installEscapeMonitors()
        refreshAvailableAutoPiPApps()
    }

    deinit {
        if let streamErrorObserver {
            NotificationCenter.default.removeObserver(streamErrorObserver)
        }
        if let appWillTerminateObserver {
            NotificationCenter.default.removeObserver(appWillTerminateObserver)
        }
        if let appActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appActivationObserver)
        }
        if let appTerminationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(appTerminationObserver)
        }
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
        }
    }

    func refreshPermissions() {
        isScreenRecordingTrusted = PermissionManager.isScreenRecordingTrusted
        isAccessibilityTrusted = PermissionManager.isAccessibilityTrusted
    }

    func requestScreenRecordingPermission() {
        PermissionManager.requestScreenRecordingPermission()
        refreshPermissions()
    }

    func requestAccessibilityPermission() {
        PermissionManager.requestAccessibilityPermission()
        refreshPermissions()
    }

    func openScreenRecordingSettings() {
        PermissionManager.openScreenRecordingSettings()
    }

    func openAccessibilitySettings() {
        PermissionManager.openAccessibilitySettings()
    }

    func setHoverSwitchEnabled(_ enabled: Bool) {
        hoverSwitchEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: "HoverSwitchEnabled")
        pipWindowController?.hoverSwitchEnabled = activePiPBehavior.allowsInteractiveControls ? enabled : false
    }

    func refreshAvailableAutoPiPApps() {
        isRefreshingAutoPiPApps = true
        let selectedApps = autoPiPAppSelections
        let excludedBundleIdentifier = Bundle.main.bundleIdentifier
        let runningApplicationURLs: [URL] = NSWorkspace.shared.runningApplications.compactMap { runningApplication -> URL? in
            guard runningApplication.activationPolicy == .regular else { return nil }
            return runningApplication.bundleURL
        }

        Task { [selectedApps, excludedBundleIdentifier, runningApplicationURLs] in
            let discoveredApps = await Task.detached(priority: .utility) {
                Self.discoverAvailableApplications(
                    excludingBundleIdentifier: excludedBundleIdentifier,
                    runningApplicationURLs: runningApplicationURLs
                )
            }.value

            self.availableAutoPiPApps = discoveredApps
            self.synchronizeAutoPiPSelections(using: discoveredApps, fallingBackTo: selectedApps)
            self.isRefreshingAutoPiPApps = false
        }
    }

    func addAutoPiPAppSelection(_ app: AutoPiPAppSelection) {
        guard !autoPiPAppSelections.contains(where: { $0.bundleIdentifier == app.bundleIdentifier }) else { return }
        autoPiPAppSelections.append(app)
        autoPiPAppSelections.sort { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        saveAutoPiPAppSelections()
    }

    func removeAutoPiPAppSelection(bundleIdentifier: String) {
        autoPiPAppSelections.removeAll { $0.bundleIdentifier == bundleIdentifier }
        saveAutoPiPAppSelections()
    }

    func hotKeyPressed() {
        Task {
            if activeTarget == nil {
                await startPiPFromFrontmostWindow()
            } else {
                await stopActivePiPFromPrimaryShortcut()
            }
        }
    }

    func exitPiP() {
        Task {
            if activePiPBehavior.cachesRestoreSnapshot {
                cacheCurrentPiPForRestore()
            } else {
                clearLastExitedPiPSnapshot()
            }
            await stopPiP(restoreSource: true, focusSource: false)
        }
    }

    func closePiP() {
        Task {
            if activePiPBehavior.cachesRestoreSnapshot {
                cacheCurrentPiPForRestore()
            } else {
                clearLastExitedPiPSnapshot()
            }
            await stopPiP(restoreSource: false, focusSource: false)
        }
    }

    private func handleSingleEscapePress() {
        guard activeTarget != nil else { return }
        lastPrimaryDoublePressDate = nil
        lastExitDoublePressDate = nil
        lastDoubleTapKeyPressDate = nil
        exitPiP()
    }

    private func isDoublePress(storedPressDate: inout Date?) -> Bool {
        let now = Date()
        let threshold: TimeInterval = 0.18

        if let previousPressDate = storedPressDate,
           now.timeIntervalSince(previousPressDate) <= threshold {
            storedPressDate = nil
            return true
        }

        storedPressDate = now
        return false
    }

    private func resetDoublePressDates() {
        lastPrimaryDoublePressDate = nil
        lastExitDoublePressDate = nil
        lastDoubleTapKeyPressDate = nil
    }

    private func handleDoubleTapKeyAction() {
        if activeTarget != nil {
            exitPiP()
        } else if let snapshot = lastExitedTargetSnapshot {
            Task {
                await restoreLastExitedPiP(snapshot)
            }
        }
    }

    private func restoreLastExitedPiP(_ target: WindowTarget) async {
        refreshPermissions()

        guard isScreenRecordingTrusted, isAccessibilityTrusted else {
            statusText = "Screen Recording and Accessibility permissions are required to restore PiP."
            return
        }

        hoverSwitchEnabled = lastExitedHoverSwitchEnabledSnapshot ?? hoverSwitchEnabled
        await beginPiP(
            for: target,
            behavior: .interactive,
            sourceFrame: lastExitedSourceFrameSnapshot ?? target.frame,
            startupStatusText: "Restoring PiP for \(target.appName)…"
        )

        if activeTarget != nil, let lastExitedHideStrategySnapshot {
            sourceHideStrategy = lastExitedHideStrategySnapshot
        }
    }

    func quitApp() {
        Task { @MainActor in
            if activeTarget != nil {
                await stopPiP(restoreSource: true, focusSource: false)
            }
            NSApplication.shared.terminate(nil)
        }
    }

    private func registerHotKey() {
        guard primaryShortcutMode == .modifierKey else {
            hotKey = nil
            return
        }
        hotKey = GlobalHotKey(keyCode: currentKeyCode, modifiers: currentModifiers) { [weak self] in
            self?.hotKeyPressed()
        }
    }

    private func registerDoubleTapActionHotKey() {
        guard doubleTapShortcutMode == .modifierKey else {
            doubleTapActionHotKey = nil
            return
        }
        doubleTapActionHotKey = GlobalHotKey(
            keyCode: currentDoubleTapHotKeyCode,
            modifiers: currentDoubleTapHotKeyModifiers
        ) { [weak self] in
            self?.handleDoubleTapKeyAction()
        }
    }

    func setHotKeyRecordingActive(_ isActive: Bool) {
        isHotKeyRecordingActive = isActive
        if isActive {
            hotKey = nil
            doubleTapActionHotKey = nil
        } else {
            if hotKey == nil { registerHotKey() }
            if doubleTapActionHotKey == nil { registerDoubleTapActionHotKey() }
        }
    }

    func setPrimaryShortcutMode(_ mode: ShortcutTriggerMode) {
        primaryShortcutMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "PrimaryShortcutMode")
        hotKey = nil
        registerHotKey()
        resetDoublePressDates()
    }

    func setDoubleTapShortcutMode(_ mode: ShortcutTriggerMode) {
        doubleTapShortcutMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: "DoubleTapShortcutMode")
        doubleTapActionHotKey = nil
        registerDoubleTapActionHotKey()
        resetDoublePressDates()
    }

    func applyPrimaryShortcutFromInput() {
        switch primaryShortcutMode {
        case .modifierKey:
            applyPrimaryHotKeyFromInput()
        case .doublePress:
            applyPrimaryDoubleTapKeyFromInput()
        case .singleKey:
            applyPrimarySingleKeyFromInput()
        }
    }

    func applyDoubleTapActionShortcutFromInput() {
        switch doubleTapShortcutMode {
        case .modifierKey:
            applyDoubleTapActionHotKeyFromInput()
        case .doublePress:
            applyDoubleTapKeyFromInput()
        case .singleKey:
            applyDoubleTapSingleKeyFromInput()
        }
    }

    private func applyPrimaryHotKeyFromInput() {
        let input = hotkeyInput
        guard let parsed = parseHotkey(from: input) else {
            statusText = "Invalid shortcut. Use e.g. ⌥P or option+p."
            return
        }
        currentKeyCode = parsed.keyCode
        currentModifiers = parsed.modifiers
        hotKey = nil
        registerHotKey()
        UserDefaults.standard.set(input, forKey: "HotkeyInput")
        statusText = "PiP shortcut set to \(displayString(for: currentModifiers, keyCode: currentKeyCode))."
    }

    private func applyDoubleTapActionHotKeyFromInput() {
        let input = doubleTapHotkeyInput
        guard let parsed = parseHotkey(from: input) else {
            statusText = "Invalid shortcut. Use e.g. ⌥⎋ or option+escape."
            return
        }
        currentDoubleTapHotKeyCode = parsed.keyCode
        currentDoubleTapHotKeyModifiers = parsed.modifiers
        doubleTapActionHotKey = nil
        registerDoubleTapActionHotKey()
        UserDefaults.standard.set(input, forKey: "DoubleTapHotkeyInput")
        statusText = "Exit / restore shortcut set to \(displayString(for: currentDoubleTapHotKeyModifiers, keyCode: currentDoubleTapHotKeyCode))."
    }

    private func applyPrimaryDoubleTapKeyFromInput() {
        let input = primaryDoubleTapKeyInput
        guard let keyCode = parseDoubleTapKey(from: input) else {
            statusText = "Invalid double-press key. Use one key, like Space or A."
            return
        }
        currentPrimaryDoubleTapKeyCode = keyCode
        primaryDoubleTapKeyInput = keySymbol(for: keyCode)
        resetDoublePressDates()
        UserDefaults.standard.set(primaryDoubleTapKeyInput, forKey: "PrimaryDoubleTapKeyInput")
        statusText = "PiP double-press key set to \(primaryDoubleTapKeyInput)."
    }

    private func applyDoubleTapKeyFromInput() {
        let input = doubleTapKeyInput
        guard let keyCode = parseDoubleTapKey(from: input) else {
            statusText = "Invalid double-tap key. Use one key, like ⎋, Space, or A."
            return
        }
        currentDoubleTapKeyCode = keyCode
        doubleTapKeyInput = keySymbol(for: keyCode)
        resetDoublePressDates()
        UserDefaults.standard.set(doubleTapKeyInput, forKey: "DoubleTapKeyInput")
        statusText = "Double-tap key set to \(doubleTapKeyInput)."
    }

    private func applyPrimarySingleKeyFromInput() {
        let input = primarySingleKeyInput
        guard let keyCode = parseDoubleTapKey(from: input) else {
            statusText = "Invalid single key. Use one key, like Space or A."
            return
        }
        currentPrimarySingleKeyCode = keyCode
        primarySingleKeyInput = keySymbol(for: keyCode)
        resetDoublePressDates()
        UserDefaults.standard.set(primarySingleKeyInput, forKey: "PrimarySingleKeyInput")
        statusText = "PiP single key set to \(primarySingleKeyInput)."
    }

    private func applyDoubleTapSingleKeyFromInput() {
        let input = doubleTapSingleKeyInput
        guard let keyCode = parseDoubleTapKey(from: input) else {
            statusText = "Invalid single key. Use one key, like ⎋, Space, or A."
            return
        }
        currentDoubleTapSingleKeyCode = keyCode
        doubleTapSingleKeyInput = keySymbol(for: keyCode)
        resetDoublePressDates()
        UserDefaults.standard.set(doubleTapSingleKeyInput, forKey: "DoubleTapSingleKeyInput")
        statusText = "Exit / restore single key set to \(doubleTapSingleKeyInput)."
    }

    private func parseHotkey(from input: String) -> (keyCode: UInt32, modifiers: UInt32)? {
        var modifiers: UInt32 = 0
        let lower = input.lowercased()
        if lower.contains("cmd") || input.contains("⌘") || lower.contains("command") {
            modifiers |= UInt32(cmdKey)
        }
        if lower.contains("ctrl") || lower.contains("control") || input.contains("⌃") {
            modifiers |= UInt32(controlKey)
        }
        if lower.contains("alt") || lower.contains("option") || lower.contains("opt") || input.contains("⌥") {
            modifiers |= UInt32(optionKey)
        }
        if lower.contains("shift") || input.contains("⇧") {
            modifiers |= UInt32(shiftKey)
        }

        let separators = CharacterSet.alphanumerics.inverted
        let tokens = input.components(separatedBy: separators).filter { !$0.isEmpty }
        var keyString: String?
        for token in tokens {
            let t = token.lowercased()
            if ["cmd","command","⌘","ctrl","control","⌃","alt","option","opt","⌥","shift","⇧","fn"].contains(t) {
                continue
            }
            if t.count == 1 {
                keyString = t
                break
            }
        }
        if keyString == nil {
            if input.contains("⎋") || lower.contains("escape") || lower.contains("esc") {
                keyString = "escape"
            } else if lower.contains("space") || input.contains("␣") {
                keyString = "space"
            }
        }
        if keyString == nil {
            if let ch = input.uppercased().last(where: { $0.isLetter || $0.isNumber }) {
                keyString = String(ch).lowercased()
            }
        }
        guard let keyString, let keyCode = keyCode(for: keyString) else {
            return nil
        }
        return (keyCode: keyCode, modifiers: modifiers)
    }

    private func keyCode(for key: String) -> UInt32? {
        let map: [String: UInt32] = [
            "a": UInt32(kVK_ANSI_A),
            "s": UInt32(kVK_ANSI_S),
            "d": UInt32(kVK_ANSI_D),
            "f": UInt32(kVK_ANSI_F),
            "h": UInt32(kVK_ANSI_H),
            "g": UInt32(kVK_ANSI_G),
            "z": UInt32(kVK_ANSI_Z),
            "x": UInt32(kVK_ANSI_X),
            "c": UInt32(kVK_ANSI_C),
            "v": UInt32(kVK_ANSI_V),
            "b": UInt32(kVK_ANSI_B),
            "q": UInt32(kVK_ANSI_Q),
            "w": UInt32(kVK_ANSI_W),
            "e": UInt32(kVK_ANSI_E),
            "r": UInt32(kVK_ANSI_R),
            "y": UInt32(kVK_ANSI_Y),
            "t": UInt32(kVK_ANSI_T),
            "1": UInt32(kVK_ANSI_1),
            "2": UInt32(kVK_ANSI_2),
            "3": UInt32(kVK_ANSI_3),
            "4": UInt32(kVK_ANSI_4),
            "6": UInt32(kVK_ANSI_6),
            "5": UInt32(kVK_ANSI_5),
            "9": UInt32(kVK_ANSI_9),
            "7": UInt32(kVK_ANSI_7),
            "8": UInt32(kVK_ANSI_8),
            "0": UInt32(kVK_ANSI_0),
            "o": UInt32(kVK_ANSI_O),
            "u": UInt32(kVK_ANSI_U),
            "i": UInt32(kVK_ANSI_I),
            "p": UInt32(kVK_ANSI_P),
            "l": UInt32(kVK_ANSI_L),
            "j": UInt32(kVK_ANSI_J),
            "k": UInt32(kVK_ANSI_K),
            "n": UInt32(kVK_ANSI_N),
            "m": UInt32(kVK_ANSI_M),
            "escape": UInt32(kVK_Escape),
            "esc": UInt32(kVK_Escape),
            "⎋": UInt32(kVK_Escape),
            "space": UInt32(kVK_Space)
        ]
        return map[key]
    }

    private func parseDoubleTapKey(from input: String) -> UInt16? {
        let normalized = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if ["⎋", "esc", "escape"].contains(normalized) {
            return UInt16(kVK_Escape)
        }
        if ["space", "spacebar", "␣"].contains(normalized) {
            return UInt16(kVK_Space)
        }
        if normalized.count == 1,
           let keyCode = keyCode(for: normalized) {
            return UInt16(keyCode)
        }
        if let ch = normalized.last(where: { $0.isLetter || $0.isNumber }),
           let keyCode = keyCode(for: String(ch)) {
            return UInt16(keyCode)
        }
        return nil
    }

    private func displayString(for modifiers: UInt32, keyCode: UInt32) -> String {
        var parts = ""
        if (modifiers & UInt32(cmdKey)) != 0 { parts += "⌘" }
        if (modifiers & UInt32(optionKey)) != 0 { parts += "⌥" }
        if (modifiers & UInt32(shiftKey)) != 0 { parts += "⇧" }
        if (modifiers & UInt32(controlKey)) != 0 { parts += "⌃" }
        parts += keySymbol(for: keyCode)
        return parts
    }

    private func keySymbol(for keyCode: UInt32) -> String {
        let reverse: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A",
            UInt32(kVK_ANSI_S): "S",
            UInt32(kVK_ANSI_D): "D",
            UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_H): "H",
            UInt32(kVK_ANSI_G): "G",
            UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_V): "V",
            UInt32(kVK_ANSI_B): "B",
            UInt32(kVK_ANSI_Q): "Q",
            UInt32(kVK_ANSI_W): "W",
            UInt32(kVK_ANSI_E): "E",
            UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_Y): "Y",
            UInt32(kVK_ANSI_T): "T",
            UInt32(kVK_ANSI_1): "1",
            UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3",
            UInt32(kVK_ANSI_4): "4",
            UInt32(kVK_ANSI_6): "6",
            UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_ANSI_7): "7",
            UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_0): "0",
            UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_P): "P",
            UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_J): "J",
            UInt32(kVK_ANSI_K): "K",
            UInt32(kVK_ANSI_N): "N",
            UInt32(kVK_ANSI_M): "M",
            UInt32(kVK_Escape): "⎋",
            UInt32(kVK_Space): "Space"
        ]
        return reverse[keyCode] ?? "?"
    }

    private func keySymbol(for keyCode: UInt16) -> String {
        switch Int(keyCode) {
        case kVK_Escape:
            return "⎋"
        case kVK_Space:
            return "Space"
        default:
            return keySymbol(for: UInt32(keyCode))
        }
    }

    private func stopActivePiPFromPrimaryShortcut() async {
        if activePiPBehavior.cachesRestoreSnapshot {
            cacheCurrentPiPForRestore()
        } else {
            clearLastExitedPiPSnapshot()
        }
        await stopPiP(restoreSource: true, focusSource: false)
    }

    private func startPiPFromFrontmostWindow() async {
        refreshPermissions()

        guard isScreenRecordingTrusted else {
            statusText = "Screen Recording permission is required."
            PermissionManager.requestScreenRecordingPermission()
            refreshPermissions()
            return
        }

        guard isAccessibilityTrusted else {
            statusText = "Accessibility permission is required to find, minimize, and restore the frontmost window."
            PermissionManager.requestAccessibilityPermission()
            refreshPermissions()
            return
        }

        guard let target = AccessibilityWindowController.frontmostWindow() else {
            statusText = "Could not identify the frontmost window."
            return
        }

        await beginPiP(
            for: target,
            behavior: .interactive,
            sourceFrame: target.frame,
            startupStatusText: "Starting PiP for \(target.appName)…"
        )
    }

    private func startAutomaticPiP(for app: NSRunningApplication) async {
        refreshPermissions()

        guard activeTarget == nil else { return }

        guard isScreenRecordingTrusted, isAccessibilityTrusted else {
            statusText = "Screen Recording and Accessibility permissions are required for automatic PiP."
            return
        }

        guard let target = AccessibilityWindowController.windowTarget(for: app) else {
            statusText = "Could not identify a window for \(app.localizedName ?? "the selected app")."
            return
        }

        clearLastExitedPiPSnapshot()
        await beginPiP(
            for: target,
            behavior: .passiveAutomatic,
            sourceFrame: target.frame,
            startupStatusText: "Starting automatic PiP for \(target.appName)…"
        )
    }

    private func glanceAtSourceWindow() {
        print("[AppsPIP] glanceAtSourceWindow starting. Target: \(activeTarget?.appName ?? "None")")
        guard let target = activeTarget, let sourceVisibleFrame else { 
            print("[AppsPIP] glanceAtSourceWindow aborted: activeTarget or sourceVisibleFrame is nil")
            return 
        }
        
        // 1. Un-park and raise the target window
        privateWindowAlphaController?.restore(windowID: target.windowID)
        AccessibilityWindowController.setFrame(sourceVisibleFrame, of: target.accessibilityWindow)
        AccessibilityWindowController.restore(target.accessibilityWindow)

        isGlancing = true
        pipWindowController?.setGlancing(true)

        // 2. Activate and focus the target application to bring it to the frontmost layer
        if let app = NSRunningApplication(processIdentifier: target.processID) {
            print("[AppsPIP] Activating target app: \(app.localizedName ?? "")")
            app.activate(options: [.activateIgnoringOtherApps])
        }

        statusText = hoverSwitchEnabled
            ? "Glancing at source window. Hover over the return PiP or press ⌥P to return focus to PiP."
            : "Glancing at source window. Press ⌥P to return focus to PiP."
        print("[AppsPIP] glanceAtSourceWindow completed. isGlancing is now true.")
    }

    private func sendBackToPiP() {
        print("[AppsPIP] sendBackToPiP starting.")
        if let target = activeTarget,
           let currentFrame = AccessibilityWindowController.currentFrame(of: target.accessibilityWindow) {
            print("[AppsPIP] Captured current frame of target window: \(currentFrame)")
            sourceVisibleFrame = currentFrame
        }
        isGlancing = false
        hideSourceWindow()
        pipWindowController?.setGlancing(false)
        pipWindowController?.show()
        statusText = runningStatusText
        print("[AppsPIP] sendBackToPiP completed. isGlancing is now false.")
    }

    private func toggleGlance() {
        print("[AppsPIP] toggleGlance called. Current isGlancing: \(isGlancing)")
        if isGlancing {
            sendBackToPiP()
        } else {
            glanceAtSourceWindow()
        }
    }

    private func handlePiPClick() {
        switch activePiPBehavior {
        case .interactive:
            toggleGlance()
        case .passiveAutomatic:
            Task {
                if activePiPBehavior.cachesRestoreSnapshot {
                    cacheCurrentPiPForRestore()
                }
                returnAutomaticPiPToSource()
                await stopPiP(restoreSource: false, focusSource: false)
            }
        }
    }

    private func returnAutomaticPiPToSource() {
        guard let target = activeTarget else { return }

        if let sourceVisibleFrame {
            AccessibilityWindowController.setFrame(sourceVisibleFrame, of: target.accessibilityWindow)
        }
        privateWindowAlphaController?.restore(windowID: target.windowID)
        AccessibilityWindowController.restore(target.accessibilityWindow)

        if let app = NSRunningApplication(processIdentifier: target.processID) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func shouldStopPiPAfterSourceActivation(_ activatedApp: NSRunningApplication) -> Bool {
        guard !isGlancing else { return false }
        guard activePiPBehavior == .passiveAutomatic else { return false }
        guard let target = activeTarget else { return false }
        guard activatedApp.processIdentifier == target.processID else { return false }
        if shouldIgnoreIncidentalSourceActivation() {
            return false
        }
        return true
    }

    private func shouldShowSourceForManualPiPAfterSourceActivation(_ activatedApp: NSRunningApplication) -> Bool {
        guard !isGlancing else { return false }
        guard activePiPBehavior == .interactive else { return false }
        guard let target = activeTarget else { return false }
        return activatedApp.processIdentifier == target.processID
    }

    private func showSourceForManualPiPAfterSourceActivation() {
        guard let target = activeTarget, let sourceVisibleFrame else { return }

        privateWindowAlphaController?.restore(windowID: target.windowID)
        AccessibilityWindowController.setFrame(sourceVisibleFrame, of: target.accessibilityWindow)
        AccessibilityWindowController.restore(target.accessibilityWindow)

        isGlancing = true
        pipWindowController?.setGlancing(true)
        statusText = hoverSwitchEnabled
            ? "Source window is active. Leave it to return to PiP, or hover over the return PiP to send it back."
            : "Source window is active. Leave it to return to PiP."
    }

    private func shouldIgnoreIncidentalSourceActivation() -> Bool {
        guard activePiPBehavior == .passiveAutomatic,
              let ignoreNextSourceActivationUntil else {
            return false
        }

        if Date() <= ignoreNextSourceActivationUntil {
            self.ignoreNextSourceActivationUntil = nil
            return true
        }

        self.ignoreNextSourceActivationUntil = nil
        return false
    }

    private func stopPiP(restoreSource: Bool, focusSource: Bool = true) async {
        let target = activeTarget
        let restoreFrame = sourceVisibleFrame
        let wasGlancing = isGlancing
        activeTarget = nil
        activeTargetDescription = nil
        sourceVisibleFrame = nil
        sourceHideStrategy = nil
        isGlancing = false
        activePiPBehavior = .interactive
        automaticPiPStartInFlightProcessID = nil
        ignoreNextSourceActivationUntil = nil

        await captureSession?.stop()
        captureSession = nil

        pipWindowController?.onExit = nil
        if wasGlancing {
            pipWindowController?.setGlancing(false, animated: false)
        }
        pipWindowController?.persistFrame()
        pipWindowController?.stop()
        pipWindowController = nil

        if let hiddenApp {
            hiddenApp.unhide()
            self.hiddenApp = nil
        }

        if let target {
            privateWindowAlphaController?.restore(windowID: target.windowID)
        }

        if restoreSource, let target {
            if let restoreFrame {
                AccessibilityWindowController.setFrame(restoreFrame, of: target.accessibilityWindow)
            }
            if focusSource {
                AccessibilityWindowController.restore(target.accessibilityWindow)
            } else {
                windowOrderController?.sendToBack(windowID: target.windowID)
            }
        }

        statusText = "Ready. Press ⌥P to create PiP from the frontmost window."
    }

    private func cacheCurrentPiPForRestore() {
        guard let target = activeTarget else { return }
        lastExitedTargetSnapshot = target
        lastExitedSourceFrameSnapshot = sourceVisibleFrame ?? target.frame
        lastExitedHideStrategySnapshot = sourceHideStrategy
        lastExitedHoverSwitchEnabledSnapshot = hoverSwitchEnabled
    }

    private func clearLastExitedPiPSnapshot() {
        lastExitedTargetSnapshot = nil
        lastExitedSourceFrameSnapshot = nil
        lastExitedHideStrategySnapshot = nil
        lastExitedHoverSwitchEnabledSnapshot = nil
    }

    private func installEscapeMonitors() {
        removeEscapeMonitors()

        globalKeyDownMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handlePotentialQuitShortcut(event)
            self?.handlePotentialEscape(event)
        }
        localKeyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handlePotentialQuitShortcut(event)
            self?.handlePotentialEscape(event)
            return event
        }
    }

    private func removeEscapeMonitors() {
        if let globalKeyDownMonitor {
            NSEvent.removeMonitor(globalKeyDownMonitor)
            self.globalKeyDownMonitor = nil
        }
        if let localKeyDownMonitor {
            NSEvent.removeMonitor(localKeyDownMonitor)
            self.localKeyDownMonitor = nil
        }
    }

    private func handlePotentialEscape(_ event: NSEvent) {
        guard !isHotKeyRecordingActive else { return }

        if event.keyCode == UInt16(kVK_Escape) {
            handleSingleEscapePress()
        }

        let shortcutModifiers = event.modifierFlags.intersection([.command, .option, .shift, .control])
        guard shortcutModifiers.isEmpty else { return }

        if primaryShortcutMode == .singleKey,
           event.keyCode == currentPrimarySingleKeyCode {
            resetDoublePressDates()
            hotKeyPressed()
            return
        }

        if doubleTapShortcutMode == .singleKey,
           event.keyCode == currentDoubleTapSingleKeyCode {
            resetDoublePressDates()
            handleDoubleTapKeyAction()
            return
        }

        if primaryShortcutMode == .doublePress,
           event.keyCode == currentPrimaryDoubleTapKeyCode {
            if isDoublePress(storedPressDate: &lastPrimaryDoublePressDate) {
                resetDoublePressDates()
                hotKeyPressed()
            }
            return
        }

        if doubleTapShortcutMode == .doublePress,
           event.keyCode == currentDoubleTapKeyCode {
            if isDoublePress(storedPressDate: &lastDoubleTapKeyPressDate) {
                resetDoublePressDates()
                handleDoubleTapKeyAction()
            }
        }
    }

    private func handlePotentialQuitShortcut(_ event: NSEvent) {
        guard event.keyCode == UInt16(kVK_ANSI_Q),
              event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
              let activeTarget,
              let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.processIdentifier != activeTarget.processID,
              frontmostApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        ignoreNextSourceActivationUntil = Date().addingTimeInterval(1.5)
    }

    private func hideSourceWindow() {
        guard let target = activeTarget, let sourceVisibleFrame else { return }

        // 1. Park the window far offscreen (multi-monitor safe) so it remains active and rendering
        if AccessibilityWindowController.fakeHide(target.accessibilityWindow, preserving: sourceVisibleFrame) {
            sourceHideStrategy = .fakeHide
            return
        }

        // 2. Fall back to private window alpha
        if privateWindowAlphaController?.hide(windowID: target.windowID) == true {
            sourceHideStrategy = .privateAlpha
            return
        }

        let privateAlphaFailure = privateWindowAlphaController?.lastHideAttemptDescription ?? "Private alpha symbols are unavailable."
        privateWindowAlphaController?.restore(windowID: target.windowID)

        sourceHideStrategy = .privateAlphaFailed(privateAlphaFailure)
    }

    private var runningStatusText: String {
        let interactionHint: String
        switch activePiPBehavior {
        case .interactive:
            interactionHint = "Click the PiP or press \(hotkeyInput) to glance; click Exit to stop."
        case .passiveAutomatic:
            interactionHint = "Click the PiP to return to the app, or press \(doubleTapActionInstructionText) to exit this PiP."
        }

        switch sourceHideStrategy {
        case .hiddenApp:
            return "Live PiP is running with the source app hidden. \(interactionHint)"
        case .privateAlpha:
            return "Live PiP is running with the source transparent. \(interactionHint)"
        case .privateAlphaFailed(let detail):
            return "Private alpha did not hide the source. \(detail) \(interactionHint)"
        case .fakeHide, nil:
            return "Live PiP is running with the source fake-hidden. \(interactionHint)"
        }
    }

    private func restoreSourceWindowBeforeTermination() {
        guard let target = activeTarget else { return }

        if let hiddenApp {
            hiddenApp.unhide()
            self.hiddenApp = nil
        }

        privateWindowAlphaController?.restore(windowID: target.windowID)

        if let sourceVisibleFrame {
            AccessibilityWindowController.setFrame(sourceVisibleFrame, of: target.accessibilityWindow)
        }
        AccessibilityWindowController.restore(target.accessibilityWindow)
    }

    private func handleApplicationTermination(_ terminatedApp: NSRunningApplication) {
        guard activePiPBehavior == .passiveAutomatic,
              let activeTarget,
              terminatedApp.processIdentifier != activeTarget.processID,
              terminatedApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        ignoreNextSourceActivationUntil = Date().addingTimeInterval(1.5)
    }

    private func handleAutomaticPiPActivation(previousApp: NSRunningApplication?, activatedApp: NSRunningApplication) {
        guard activeTarget == nil else { return }
        guard activatedApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard activatedApp.activationPolicy == .regular else { return }
        guard let previousApp else { return }
        guard previousApp.processIdentifier != activatedApp.processIdentifier else { return }
        guard previousApp.processIdentifier != ProcessInfo.processInfo.processIdentifier else { return }
        guard previousApp.activationPolicy == .regular else { return }
        guard let bundleIdentifier = previousApp.bundleIdentifier,
              autoPiPAppSelections.contains(where: { $0.bundleIdentifier == bundleIdentifier }) else {
            return
        }
        guard automaticPiPStartInFlightProcessID == nil else { return }

        automaticPiPStartInFlightProcessID = previousApp.processIdentifier

        Task { @MainActor in
            defer { self.automaticPiPStartInFlightProcessID = nil }
            await self.startAutomaticPiP(for: previousApp)
        }
    }

    private func beginPiP(
        for target: WindowTarget,
        behavior: PiPEntryBehavior,
        sourceFrame: CGRect,
        startupStatusText: String
    ) async {
        statusText = startupStatusText
        activePiPBehavior = behavior
        activeTarget = target
        sourceVisibleFrame = sourceFrame
        activeTargetDescription = "\(target.appName): \(target.title)"

        let pipWindowController = PiPWindowController(
            title: target.appName,
            sourceFrame: target.frame,
            restoredFrame: behavior.usesSavedManualFrame ? PiPWindowController.restoredFrame() : nil,
            shouldPersistFrame: behavior.usesSavedManualFrame
        )
        pipWindowController.hoverSwitchEnabled = behavior.allowsInteractiveControls ? hoverSwitchEnabled : false
        pipWindowController.allowsClickToSource = true
        pipWindowController.allowsInteractiveControls = behavior.allowsInteractiveControls
        pipWindowController.onGlance = { [weak self] in
            self?.handlePiPClick()
        }
        pipWindowController.onExit = { [weak self] in
            self?.exitPiP()
        }
        pipWindowController.onClose = { [weak self] in
            self?.closePiP()
        }
        self.pipWindowController = pipWindowController

        let captureSession = WindowCaptureSession { [weak self] sampleBuffer in
            self?.pipWindowController?.enqueue(sampleBuffer)
        }
        self.captureSession = captureSession

        do {
            try await captureSession.start(windowID: target.windowID)
            pipWindowController.show()
            hideSourceWindow()
            statusText = runningStatusText
        } catch {
            statusText = error.localizedDescription
            await stopPiP(restoreSource: false)
        }
    }

    private func loadAutoPiPAppSelections() {
        guard let data = UserDefaults.standard.data(forKey: Self.autoPiPAppSelectionsKey),
              let decodedSelections = try? JSONDecoder().decode([AutoPiPAppSelection].self, from: data) else {
            autoPiPAppSelections = []
            return
        }

        autoPiPAppSelections = decodedSelections.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    private func saveAutoPiPAppSelections() {
        guard let encodedSelections = try? JSONEncoder().encode(autoPiPAppSelections) else { return }
        UserDefaults.standard.set(encodedSelections, forKey: Self.autoPiPAppSelectionsKey)
    }

    private func synchronizeAutoPiPSelections(
        using discoveredApps: [AutoPiPAppSelection],
        fallingBackTo previousSelections: [AutoPiPAppSelection]
    ) {
        let nameByBundleIdentifier = Dictionary(uniqueKeysWithValues: discoveredApps.map { ($0.bundleIdentifier, $0.displayName) })
        let currentSelections = autoPiPAppSelections.isEmpty ? previousSelections : autoPiPAppSelections
        let synchronizedSelections = currentSelections.map { selection in
            AutoPiPAppSelection(
                bundleIdentifier: selection.bundleIdentifier,
                displayName: nameByBundleIdentifier[selection.bundleIdentifier] ?? selection.displayName
            )
        }
        .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

        if synchronizedSelections != autoPiPAppSelections {
            autoPiPAppSelections = synchronizedSelections
            saveAutoPiPAppSelections()
        }
    }

    nonisolated private static func discoverAvailableApplications(
        excludingBundleIdentifier: String?,
        runningApplicationURLs: [URL]
    ) -> [AutoPiPAppSelection] {
        var applicationsByBundleIdentifier: [String: AutoPiPAppSelection] = [:]

        func registerApplication(at url: URL) {
            guard let bundle = Bundle(url: url),
                  let bundleIdentifier = bundle.bundleIdentifier,
                  bundleIdentifier != excludingBundleIdentifier else {
                return
            }

            let displayName = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (bundle.object(forInfoDictionaryKey: kCFBundleNameKey as String) as? String)
                ?? url.deletingPathExtension().lastPathComponent

            guard !displayName.isEmpty else { return }

            applicationsByBundleIdentifier[bundleIdentifier] = AutoPiPAppSelection(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName
            )
        }

        for bundleURL in runningApplicationURLs {
            registerApplication(at: bundleURL)
        }

        let searchDirectories = [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
        ]

        for directory in searchDirectories {
            guard let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else {
                continue
            }

            for case let fileURL as URL in enumerator {
                guard fileURL.pathExtension.lowercased() == "app" else { continue }
                registerApplication(at: fileURL)
                enumerator.skipDescendants()
            }
        }

        return applicationsByBundleIdentifier.values.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }
}
