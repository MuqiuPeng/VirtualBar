import Cocoa
import ApplicationServices

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private struct OnScreenWindow {
        let frame: CGRect
        let layer: Int
    }

    private var toggleItem: NSStatusItem!
    private var spacerItem: NSStatusItem!
    private let registry = ItemRegistry()
    private let preferences = ItemPreferences()
    private let panel = HiddenItemsPanel()
    private lazy var settingsWindowController = SettingsWindowController(
        preferences: preferences,
        onChange: { [weak self] in self?.settingsDidChange() },
        onRefresh: { [weak self] in self?.refreshSettings() }
    )
    private var panelLoadTask: Task<Void, Never>?
    private var settingsCaptureTask: Task<Void, Never>?
    private var registryTimer: Timer?
    private var settingsImages: [CGWindowID: NSImage] = [:]
    private var activationTask: Task<Void, Never>?
    private var activationMouseMonitor: Any?
    private var activationWorkspaceObserver: NSObjectProtocol?
    private var activationTargetPID: pid_t?
    private var activationBaselineWindowIDs: Set<CGWindowID> = []
    private var activationDismissRequested = false
    private var activationTargetBecameActive = false
    private var terminationSources: [DispatchSourceSignal] = []
    private var isReady = false
    private let foldedLength: CGFloat = 10_000
    /// Whether the third-party items are currently folded away. Tracked so
    /// "Show Real Items" can offer a way back.
    private var isFolded = false

    private var ownPID: pid_t { ProcessInfo.processInfo.processIdentifier }

    func applicationDidFinishLaunching(_ notification: Notification) {
        ProcessInfo.processInfo.disableAutomaticTermination("VirtualBar is a menu bar utility with no windows")
        seedPositions()
        createControls()
        requestPermissions()
        installSignalHandlers()
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard let self else { return }
            while !AXIsProcessTrusted() {
                toggleItem.button?.toolTip = "Enable Accessibility for VirtualBar"
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
            }
            refreshRegistry()
            setFolded(true)
            isReady = true
            toggleItem.button?.toolTip = "Show Virtual Bar"
            startRegistryTimer()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        registryTimer?.invalidate()
        settingsCaptureTask?.cancel()
        restoreAllItems()
    }

    private func seedPositions() {
        let defaults = UserDefaults.standard
        defaults.set(310, forKey: "NSStatusItem Preferred Position VirtualBarToggle")
        defaults.set(311, forKey: "NSStatusItem Preferred Position VirtualBarSpacer")
    }

    private func createControls() {
        toggleItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        toggleItem.autosaveName = "VirtualBarToggle"
        toggleItem.button?.image = virtualBarTabImage()
        toggleItem.button?.imagePosition = .imageOnly
        toggleItem.button?.imageScaling = .scaleNone
        toggleItem.button?.alignment = .center
        toggleItem.button?.toolTip = "Show Virtual Bar"
        toggleItem.button?.target = self
        toggleItem.button?.action = #selector(togglePressed)
        toggleItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])

        spacerItem = NSStatusBar.system.statusItem(withLength: 0)
        spacerItem.autosaveName = "VirtualBarSpacer"
        spacerItem.button?.title = ""
        panel.toggleWindow = toggleItem.button?.window
    }

    private func virtualBarTabImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 28, height: 18), flipped: false) { _ in
            NSColor.black.setFill()
            for x in [5.5, 14, 22.5] as [CGFloat] {
                NSBezierPath(ovalIn: NSRect(x: x - 2.5, y: 6.5, width: 5, height: 5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "VirtualBar"
        return image
    }

    private func requestPermissions() {
        let trusted = AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true
        ] as CFDictionary)
        let capture = CGPreflightScreenCaptureAccess()
        if !capture {
            CGRequestScreenCaptureAccess()
        }
        debugLog("VirtualBar permissions accessibility=\(trusted) screenCapture=\(capture)")
    }

    private func installSignalHandlers() {
        for value in [SIGTERM, SIGINT] {
            signal(value, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: value, queue: .main)
            source.setEventHandler { [weak self] in
                self?.restoreAllItems()
                exit(0)
            }
            source.resume()
            terminationSources.append(source)
        }
    }

    @objc private func togglePressed() {
        guard let event = NSApp.currentEvent else { return }
        if event.type == .rightMouseUp {
            showSettings(with: event)
            return
        }
        guard isReady, activationTask == nil else { return }
        if panel.isVisible || panelLoadTask != nil {
            closeVirtualBar()
        } else {
            openVirtualBar()
        }
    }

    private func openVirtualBar() {
        if !isFolded { setFolded(true) }
        refreshRegistry()
        let items = preferences.displayed(configurableItems)
        guard !items.isEmpty,
              let screen = toggleItem.button?.window?.screen ?? NSScreen.main else {
            NSSound.beep()
            return
        }
        let anchor = toggleItem.button?.window?.frame ?? .zero
        toggleItem.button?.toolTip = "Loading Virtual Bar"
        panelLoadTask = Task { [weak self] in
            let images = await IconCapture.capture(items)
            guard let self, !Task.isCancelled else { return }
            panelLoadTask = nil
            toggleItem.button?.toolTip = "Hide Virtual Bar"
            panel.show(items: items, images: images, on: screen, anchoredTo: anchor) { [weak self] item in
                self?.activate(item)
            }
            debugLog("VirtualBar virtualBar visible=true items=\(items.count)")
        }
    }

    private func closeVirtualBar() {
        panelLoadTask?.cancel()
        panelLoadTask = nil
        panel.close()
        toggleItem.button?.toolTip = "Show Virtual Bar"
    }

    private func activate(_ selectedItem: MenuBarItem) {
        closeVirtualBar()
        stopActivationFocusMonitoring()
        debugLog("VirtualBar virtualBar visible=\(panel.isVisible) selected=\(selectedItem.ownerName)")
        activationTask?.cancel()
        activationTask = Task { [weak self] in
            guard let self else { return }
            setFolded(false)
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, let item = resolve(selectedItem) else {
                finishActivation()
                return
            }
            let baseline = onScreenWindowIDs(for: item.pid)
            let frontmostBeforePress = NSWorkspace.shared.frontmostApplication?.processIdentifier
            let pressed = MenuBarItems.press(item)
            debugLog("VirtualBar activate owner=\(item.ownerName) pid=\(item.pid) window=\(item.windowID) pressed=\(pressed)")
            if pressed {
                await waitForPresentedInterface(
                    pid: item.pid,
                    baseline: baseline,
                    frontmostBeforePress: frontmostBeforePress
                )
            }
            guard !Task.isCancelled else { return }
            finishActivation()
        }
    }

    private func resolve(_ selectedItem: MenuBarItem) -> MenuBarItem? {
        let current = MenuBarItems.scanAll().filter {
            $0.pid != ownPID && $0.kind == .thirdParty
        }
        if let sameWindow = current.first(where: { $0.windowID == selectedItem.windowID }) {
            return sameWindow
        }
        if let sameIdentity = current.first(where: { $0.id == selectedItem.id }) {
            return sameIdentity
        }
        return current.min { lhs, rhs in
            fallbackDistance(lhs, from: selectedItem) < fallbackDistance(rhs, from: selectedItem)
        }.flatMap { fallbackDistance($0, from: selectedItem) < 1_000 ? $0 : nil }
    }

    private func fallbackDistance(_ candidate: MenuBarItem, from selectedItem: MenuBarItem) -> Int {
        var value = 0
        if candidate.pid != selectedItem.pid { value += 10_000 }
        if candidate.bundleIdentifier != selectedItem.bundleIdentifier { value += 5_000 }
        if candidate.ownerName != selectedItem.ownerName { value += 2_000 }
        value += abs(candidate.id.widthClass - selectedItem.id.widthClass) * 10
        value += abs(candidate.order - selectedItem.order)
        return value
    }

    private func waitForPresentedInterface(
        pid: pid_t,
        baseline: Set<CGWindowID>,
        frontmostBeforePress: pid_t?
    ) async {
        startActivationFocusMonitoring(
            pid: pid,
            baseline: baseline,
            frontmostBeforePress: frontmostBeforePress
        )
        defer { stopActivationFocusMonitoring() }
        let discoveryDeadline = ContinuousClock.now + .seconds(5)
        var discovered = false
        var navigationCandidateSince: ContinuousClock.Instant?
        while !Task.isCancelled && ContinuousClock.now < discoveryDeadline {
            if await finishAfterFocusLossIfNeeded(pid: pid) { return }
            let allNewWindows = onScreenWindows(for: pid).filter { !baseline.contains($0.key) }
            let presentedWindows = allNewWindows.filter { isPresentedInterfaceWindow($0.value) }
            if !presentedWindows.isEmpty {
                discovered = true
                debugLog("VirtualBar presentedInterface discovered pid=\(pid)")
                break
            }
            let hasNavigationWindow = allNewWindows.contains { !isPresentedInterfaceWindow($0.value) }
            let targetIsFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            if hasNavigationWindow || activationTargetBecameActive || targetIsFrontmost {
                if let navigationCandidateSince {
                    if ContinuousClock.now - navigationCandidateSince >= .milliseconds(600) {
                        debugLog("VirtualBar windowNavigation completed pid=\(pid) newWindow=\(hasNavigationWindow) frontmost=\(targetIsFrontmost)")
                        return
                    }
                } else {
                    navigationCandidateSince = .now
                }
            } else {
                navigationCandidateSince = nil
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        if !discovered {
            let fallbackDeadline = ContinuousClock.now + .seconds(20)
            while !Task.isCancelled && ContinuousClock.now < fallbackDeadline {
                if await finishAfterFocusLossIfNeeded(pid: pid) { return }
                try? await Task.sleep(for: .milliseconds(125))
            }
            return
        }
        var emptyChecks = 0
        while !Task.isCancelled {
            if await finishAfterFocusLossIfNeeded(pid: pid) { return }
            let presented = presentedInterfaceWindows(for: pid, baseline: baseline)
            if presented.isEmpty {
                emptyChecks += 1
                if emptyChecks >= 8 {
                    debugLog("VirtualBar presentedInterface closed pid=\(pid)")
                    return
                }
            } else {
                emptyChecks = 0
            }
            try? await Task.sleep(for: .milliseconds(125))
        }
    }

    private func startActivationFocusMonitoring(
        pid: pid_t,
        baseline: Set<CGWindowID>,
        frontmostBeforePress: pid_t?
    ) {
        stopActivationFocusMonitoring()
        activationTargetPID = pid
        activationBaselineWindowIDs = baseline
        activationDismissRequested = false
        activationTargetBecameActive = frontmostBeforePress != pid && NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
        let mouseMask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        activationMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: mouseMask) { [weak self] event in
            let location = event.cgEvent?.location
            Task { @MainActor [weak self] in
                self?.handleActivationMouseDown(at: location)
            }
        }
        activationWorkspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            Task { @MainActor [weak self] in
                guard let self,
                      let targetPID = activationTargetPID else {
                    return
                }
                if application.processIdentifier == targetPID {
                    activationTargetBecameActive = true
                    debugLog("VirtualBar targetApplication activated pid=\(targetPID)")
                    return
                }
                activationDismissRequested = true
                debugLog("VirtualBar focusLoss application pid=\(targetPID) activated=\(application.processIdentifier)")
            }
        }
    }

    private func handleActivationMouseDown(at location: CGPoint?) {
        guard let pid = activationTargetPID else { return }
        if let location {
            let presentedFrames = presentedInterfaceWindows(
                for: pid,
                baseline: activationBaselineWindowIDs
            ).values.map(\.frame)
            if presentedFrames.contains(where: { $0.insetBy(dx: -4, dy: -4).contains(location) }) {
                return
            }
        }
        activationDismissRequested = true
        debugLog("VirtualBar focusLoss outsideClick pid=\(pid)")
    }

    private func finishAfterFocusLossIfNeeded(pid: pid_t) async -> Bool {
        guard activationDismissRequested else { return false }
        try? await Task.sleep(for: .milliseconds(250))
        guard !Task.isCancelled else { return true }
        debugLog("VirtualBar presentedInterface focusLost pid=\(pid)")
        return true
    }

    private func stopActivationFocusMonitoring() {
        if let activationMouseMonitor {
            NSEvent.removeMonitor(activationMouseMonitor)
            self.activationMouseMonitor = nil
        }
        if let activationWorkspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(activationWorkspaceObserver)
            self.activationWorkspaceObserver = nil
        }
        activationTargetPID = nil
        activationBaselineWindowIDs.removeAll()
        activationDismissRequested = false
        activationTargetBecameActive = false
    }

    private func onScreenWindowIDs(for pid: pid_t) -> Set<CGWindowID> {
        Set(onScreenWindows(for: pid).keys)
    }

    private func presentedInterfaceWindows(
        for pid: pid_t,
        baseline: Set<CGWindowID>
    ) -> [CGWindowID: OnScreenWindow] {
        onScreenWindows(for: pid).filter {
            !baseline.contains($0.key) && isPresentedInterfaceWindow($0.value)
        }
    }

    private func isPresentedInterfaceWindow(_ window: OnScreenWindow) -> Bool {
        let popupLevel = Int(CGWindowLevelForKey(.popUpMenuWindow))
        if window.layer >= popupLevel { return true }
        return window.frame.width <= 600 &&
            window.frame.height <= 650 &&
            window.frame.minY <= 120
    }

    private func onScreenWindows(for pid: pid_t) -> [CGWindowID: OnScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: list.compactMap { info in
            guard let owner = info[kCGWindowOwnerPID as String] as? Int,
                  owner == Int(pid),
                  let number = info[kCGWindowNumber as String] as? Int,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  (bounds["Width"] ?? 0) > 1,
                  (bounds["Height"] ?? 0) > 1 else {
                return nil
            }
            let visible = (info[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            let alpha = info[kCGWindowAlpha as String] as? Double ?? 1
            guard visible && alpha > 0 else { return nil }
            let frame = CGRect(
                x: bounds["X"] ?? 0,
                y: bounds["Y"] ?? 0,
                width: bounds["Width"] ?? 0,
                height: bounds["Height"] ?? 0
            )
            return (CGWindowID(number), OnScreenWindow(frame: frame, layer: layer))
        })
    }

    private func finishActivation() {
        stopActivationFocusMonitoring()
        setFolded(true)
        refreshRegistry()
        activationTask = nil
        toggleItem.button?.toolTip = "Show Virtual Bar"
    }

    @discardableResult
    private func refreshRegistry() -> Bool {
        let registryChanged = registry.refresh(ownPID: ownPID, leftOf: nil)
        let preferencesChanged = preferences.reconcile(configurableItems)
        let changed = registryChanged || preferencesChanged
        if settingsWindowController.isVisible && changed {
            settingsWindowController.update(items: configurableItems, images: settingsImages)
            captureSettingsImages(for: configurableItems)
        }
        guard changed else { return false }
        let value = registry.items.map {
            "id=\($0.id) pid=\($0.pid) window=\($0.windowID) frame=\(NSStringFromRect($0.frame)) order=\($0.order) capability=\($0.capability.rawValue)"
        }.joined(separator: "\n")
        debugLog("VirtualBar registry revision=\(registry.revision) items=\(registry.items.count)\n\(value)")
        return true
    }

    private var configurableItems: [MenuBarItem] {
        registry.items.filter { $0.capability.contains(.accessibilityPress) }
    }

    private func startRegistryTimer() {
        registryTimer?.invalidate()
        registryTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshRegistry()
            }
        }
    }

    private func setFolded(_ folded: Bool) {
        isFolded = folded
        spacerItem?.length = folded ? foldedLength : 0
        debugLog("VirtualBar folded=\(folded) spacer=\(spacerItem?.length ?? 0)")
    }

    private func showSettings(with event: NSEvent) {
        guard let button = toggleItem.button else { return }
        let menu = NSMenu()
        let show = menu.addItem(withTitle: "Show Virtual Bar", action: #selector(showVirtualBarFromMenu), keyEquivalent: "")
        show.target = self
        let settings = menu.addItem(withTitle: "Settings…", action: #selector(showSettingsWindowFromMenu), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let refresh = menu.addItem(withTitle: "Refresh Items", action: #selector(refreshFromMenu), keyEquivalent: "r")
        refresh.target = self
        let reveal = menu.addItem(
            withTitle: isFolded ? "Show Real Items" : "Hide Real Items",
            action: #selector(toggleRealItems),
            keyEquivalent: ""
        )
        reveal.target = self
        reveal.state = isFolded ? .off : .on
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit VirtualBar", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    @objc private func showVirtualBarFromMenu() {
        guard activationTask == nil else { return }
        openVirtualBar()
    }

    @objc private func refreshFromMenu() {
        refreshRegistry()
    }

    @objc private func showSettingsWindowFromMenu() {
        showSettingsWindow()
    }

    private func showSettingsWindow() {
        closeVirtualBar()
        refreshRegistry()
        settingsWindowController.show(items: configurableItems, images: settingsImages)
        captureSettingsImages(for: configurableItems)
    }

    private func refreshSettings() {
        refreshRegistry()
        settingsWindowController.update(items: configurableItems, images: settingsImages)
        captureSettingsImages(for: configurableItems)
    }

    private func captureSettingsImages(for items: [MenuBarItem]) {
        settingsCaptureTask?.cancel()
        settingsCaptureTask = Task { [weak self] in
            let images = await IconCapture.capture(items)
            guard let self, !Task.isCancelled else { return }
            settingsCaptureTask = nil
            settingsImages = images
            if settingsWindowController.isVisible {
                settingsWindowController.update(items: configurableItems, images: images)
            }
        }
    }

    private func settingsDidChange() {
        closeVirtualBar()
        settingsWindowController.update(items: configurableItems, images: settingsImages)
        debugLog("VirtualBar settings visible=\(preferences.displayed(configurableItems).count) total=\(configurableItems.count)")
    }

    /// Reveals the real status items, or folds them back again.
    ///
    /// This has to be a toggle. Revealing cancels the activation task, and
    /// that task owns the only other call to `finishActivation()` — so a
    /// one-way "show" left the menu bar expanded with nothing able to fold it
    /// back short of relaunching.
    @objc private func toggleRealItems() {
        closeVirtualBar()
        activationTask?.cancel()
        activationTask = nil
        stopActivationFocusMonitoring()
        setFolded(!isFolded)
        toggleItem.button?.toolTip = isFolded ? "Show Virtual Bar" : "Real items shown"
    }

    @objc private func quitApp() {
        restoreAllItems()
        NSApp.terminate(nil)
    }

    private func restoreAllItems() {
        panelLoadTask?.cancel()
        settingsCaptureTask?.cancel()
        activationTask?.cancel()
        stopActivationFocusMonitoring()
        panel.close()
        spacerItem?.length = 0
    }
}
