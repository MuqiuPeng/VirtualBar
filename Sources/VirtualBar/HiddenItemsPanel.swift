import Cocoa

@MainActor
final class VirtualIconButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isPointerInside = false
    private var isPointerPressed = false

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
    }

    override func mouseEntered(with event: NSEvent) {
        isPointerInside = true
        updateBackground()
    }

    override func mouseExited(with event: NSEvent) {
        isPointerInside = false
        updateBackground()
    }

    override func mouseDown(with event: NSEvent) {
        isPointerPressed = true
        updateBackground()
        CATransaction.flush()
        super.mouseDown(with: event)
        isPointerPressed = false
        updateBackground()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBackground()
    }

    private func updateBackground() {
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous
        let alpha: CGFloat = isPointerPressed ? 0.28 : isPointerInside ? 0.14 : 0
        layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(alpha).cgColor
    }
}

@MainActor
final class HiddenItemsPanel: NSPanel {
    private enum Metrics {
        static let iconSize: CGFloat = 34
        static let cellSize: CGFloat = 40
        static let padding: CGFloat = 4
        static let gapBelowMenuBar: CGFloat = 5
        static let cornerRadius: CGFloat = 12
        static let edgeInset: CGFloat = 8
        static let maximumWidth: CGFloat = 520
        static let rightwardOffset: CGFloat = 28
    }

    private let background = NSVisualEffectView()
    private let scrollView = NSScrollView()
    private var onSelect: ((MenuBarItem) -> Void)?
    private var dismissMonitors: [Any] = []
    private var buttonItems: [CGWindowID: MenuBarItem] = [:]

    weak var toggleWindow: NSWindow?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 44),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]

        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = Metrics.cornerRadius
        background.layer?.cornerCurve = .continuous
        background.layer?.borderWidth = 0
        background.layer?.masksToBounds = true
        background.focusRingType = .none

        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.focusRingType = .none
        scrollView.contentView.focusRingType = .none
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        background.addSubview(scrollView)
        contentView = background
    }

    override var canBecomeKey: Bool { true }

    func show(
        items: [MenuBarItem],
        images: [CGWindowID: NSImage],
        on screen: NSScreen,
        anchoredTo anchor: CGRect,
        onSelect: @escaping (MenuBarItem) -> Void
    ) {
        self.onSelect = onSelect
        buttonItems.removeAll()

        let ordered = items
        guard !ordered.isEmpty else {
            close()
            return
        }

        let documentWidth = Metrics.padding * 2 + CGFloat(ordered.count) * Metrics.cellSize
        let availableWidth = max(120, screen.visibleFrame.width - Metrics.edgeInset * 2)
        let width = min(documentWidth, Metrics.maximumWidth, availableWidth)
        let height = Metrics.padding * 2 + Metrics.cellSize
        let document = NSView(frame: NSRect(x: 0, y: 0, width: documentWidth, height: height))
        document.focusRingType = .none

        for (index, item) in ordered.enumerated() {
            let button = makeButton(for: item, image: images[item.windowID])
            button.frame = NSRect(
                x: Metrics.padding + CGFloat(index) * Metrics.cellSize,
                y: Metrics.padding,
                width: Metrics.cellSize,
                height: Metrics.cellSize
            )
            document.addSubview(button)
            buttonItems[item.windowID] = item
        }

        scrollView.documentView = document
        scrollView.hasHorizontalScroller = documentWidth > width
        scrollView.frame = NSRect(x: 0, y: 0, width: width, height: height)

        let menuBarHeight = screen.frame.maxY - screen.visibleFrame.maxY
        let preferredX = anchor.maxX - width + Metrics.rightwardOffset
        let x = min(max(preferredX, screen.visibleFrame.minX + Metrics.edgeInset), screen.visibleFrame.maxX - width - Metrics.edgeInset)
        let y = screen.frame.maxY - menuBarHeight - Metrics.gapBelowMenuBar - height
        styleMask = [.borderless, .nonactivatingPanel]
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
        orderFrontRegardless()
        installDismissMonitors()
    }

    override func close() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        onSelect = nil
        super.close()
    }

    private func installDismissMonitors() {
        dismissMonitors.forEach(NSEvent.removeMonitor)
        dismissMonitors.removeAll()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            self?.close()
        }) {
            dismissMonitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            guard let self else { return event }
            if event.window !== self && event.window !== toggleWindow {
                close()
            }
            return event
        }) {
            dismissMonitors.append(local)
        }
    }

    private func makeButton(for item: MenuBarItem, image: NSImage?) -> NSButton {
        let button = VirtualIconButton(frame: .zero)
        button.bezelStyle = .regularSquare
        button.isBordered = false
        button.focusRingType = .none
        button.imageScaling = .scaleProportionallyDown
        button.toolTip = item.ownerName
        button.target = self
        button.action = #selector(buttonClicked(_:))
        button.identifier = NSUserInterfaceItemIdentifier("\(item.windowID)")
        if let image {
            image.size = NSSize(width: Metrics.iconSize, height: Metrics.iconSize)
            button.image = image
        } else {
            button.image = ItemIcon.fallback(for: item, size: Metrics.iconSize)
        }
        return button
    }

    @objc private func buttonClicked(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let windowID = UInt32(raw),
              let item = buttonItems[windowID],
              let selection = onSelect else {
            return
        }
        close()
        selection(item)
    }
}
