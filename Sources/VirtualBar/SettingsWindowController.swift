import Cocoa

@MainActor
private final class SettingsItemCell: NSTableCellView {
    let checkbox = NSButton(checkboxWithTitle: "", target: nil, action: nil)
    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let handleView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        checkbox.setButtonType(.switch)
        checkbox.title = ""
        checkbox.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .systemFont(ofSize: 13, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        handleView.image = NSImage(systemSymbolName: "line.3.horizontal", accessibilityDescription: "Drag to reorder")
        handleView.contentTintColor = .tertiaryLabelColor
        handleView.translatesAutoresizingMaskIntoConstraints = false

        addSubview(checkbox)
        addSubview(iconView)
        addSubview(nameLabel)
        addSubview(detailLabel)
        addSubview(handleView)

        NSLayoutConstraint.activate([
            checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            checkbox.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 8),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 30),
            iconView.heightAnchor.constraint(equalToConstant: 30),
            nameLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: handleView.leadingAnchor, constant: -10),
            nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: handleView.leadingAnchor, constant: -10),
            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            handleView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            handleView.centerYAnchor.constraint(equalTo: centerYAnchor),
            handleView.widthAnchor.constraint(equalToConstant: 18),
            handleView.heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func configure(item: MenuBarItem, image: NSImage?, enabled: Bool) {
        checkbox.state = enabled ? .on : .off
        checkbox.identifier = NSUserInterfaceItemIdentifier(item.id.preferenceKey)
        nameLabel.stringValue = item.ownerName
        let title = item.id.accessibilityTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        detailLabel.stringValue = title.isEmpty ? item.bundleIdentifier : title
        if let image {
            iconView.image = image
        } else {
            iconView.image = NSRunningApplication(processIdentifier: item.pid)?.icon
        }
        toolTip = item.id.description
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    private let preferences: ItemPreferences
    private let onChange: () -> Void
    private let onRefresh: () -> Void
    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private let dragType = NSPasteboard.PasteboardType("com.virtualbar.settings-item")
    private var items: [MenuBarItem] = []
    private var images: [CGWindowID: NSImage] = [:]

    var isVisible: Bool {
        window?.isVisible == true
    }

    init(preferences: ItemPreferences, onChange: @escaping () -> Void, onRefresh: @escaping () -> Void) {
        self.preferences = preferences
        self.onChange = onChange
        self.onRefresh = onRefresh
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        configureWindow()
    }

    required init?(coder: NSCoder) {
        fatalError()
    }

    func show(items: [MenuBarItem], images: [CGWindowID: NSImage]) {
        update(items: items, images: images)
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(items: [MenuBarItem], images: [CGWindowID: NSImage]) {
        self.items = preferences.ordered(items)
        self.images = images
        countLabel.stringValue = "\(self.items.filter { preferences.isEnabled($0) }.count) of \(self.items.count) icons shown"
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        items.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard items.indices.contains(row) else { return nil }
        let item = items[row]
        let cell = SettingsItemCell(frame: .zero)
        cell.identifier = NSUserInterfaceItemIdentifier("SettingsItemCell")
        cell.checkbox.target = self
        cell.checkbox.action = #selector(visibilityChanged(_:))
        cell.configure(item: item, image: images[item.windowID], enabled: preferences.isEnabled(item))
        return cell
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard items.indices.contains(row) else { return nil }
        let value = NSPasteboardItem()
        value.setString(items[row].id.preferenceKey, forType: dragType)
        return value
    }

    func tableView(
        _ tableView: NSTableView,
        validateDrop info: NSDraggingInfo,
        proposedRow row: Int,
        proposedDropOperation dropOperation: NSTableView.DropOperation
    ) -> NSDragOperation {
        tableView.setDropRow(row, dropOperation: .above)
        return info.draggingSource as? NSTableView === tableView ? .move : []
    }

    func tableView(
        _ tableView: NSTableView,
        acceptDrop info: NSDraggingInfo,
        row: Int,
        dropOperation: NSTableView.DropOperation
    ) -> Bool {
        guard let key = info.draggingPasteboard.string(forType: dragType),
              let source = items.firstIndex(where: { $0.id.preferenceKey == key }) else {
            return false
        }
        var keys = items.map { $0.id.preferenceKey }
        let moved = keys.remove(at: source)
        var destination = row
        if destination > source {
            destination -= 1
        }
        destination = min(max(destination, 0), keys.count)
        keys.insert(moved, at: destination)
        preferences.setCurrentOrder(keys)
        items = preferences.ordered(items)
        tableView.reloadData()
        tableView.selectRowIndexes(IndexSet(integer: destination), byExtendingSelection: false)
        onChange()
        return true
    }

    private func configureWindow() {
        guard let window else { return }
        window.title = "VirtualBar Settings"
        window.minSize = NSSize(width: 400, height: 380)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("VirtualBarSettings")
        window.center()

        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = root

        let title = NSTextField(labelWithString: "Virtual Bar Icons")
        title.font = .systemFont(ofSize: 20, weight: .semibold)
        title.translatesAutoresizingMaskIntoConstraints = false

        let subtitle = NSTextField(wrappingLabelWithString: "Choose which icons appear. Drag rows to change their order in the virtual Bar.")
        subtitle.textColor = .secondaryLabelColor
        subtitle.translatesAutoresizingMaskIntoConstraints = false

        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("items"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 50
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.delegate = self
        tableView.dataSource = self
        tableView.registerForDraggedTypes([dragType])
        tableView.setDraggingSourceOperationMask(.move, forLocal: true)

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let refreshButton = NSButton(title: "Refresh", target: self, action: #selector(refreshPressed))
        refreshButton.bezelStyle = .rounded
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let resetButton = NSButton(title: "Reset Order", target: self, action: #selector(resetOrderPressed))
        resetButton.bezelStyle = .rounded
        resetButton.translatesAutoresizingMaskIntoConstraints = false

        let doneButton = NSButton(title: "Done", target: self, action: #selector(donePressed))
        doneButton.bezelStyle = .rounded
        doneButton.keyEquivalent = "\r"
        doneButton.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(title)
        root.addSubview(subtitle)
        root.addSubview(countLabel)
        root.addSubview(scrollView)
        root.addSubview(refreshButton)
        root.addSubview(resetButton)
        root.addSubview(doneButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: root.topAnchor, constant: 22),
            title.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 22),
            title.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -22),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),
            subtitle.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            countLabel.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 10),
            countLabel.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            scrollView.topAnchor.constraint(equalTo: countLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 20),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -20),
            scrollView.bottomAnchor.constraint(equalTo: refreshButton.topAnchor, constant: -16),
            refreshButton.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            refreshButton.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -18),
            resetButton.leadingAnchor.constraint(equalTo: refreshButton.trailingAnchor, constant: 8),
            resetButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor),
            doneButton.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            doneButton.centerYAnchor.constraint(equalTo: refreshButton.centerYAnchor)
        ])
    }

    @objc private func visibilityChanged(_ sender: NSButton) {
        guard let key = sender.identifier?.rawValue else { return }
        preferences.setEnabled(sender.state == .on, for: key)
        countLabel.stringValue = "\(items.filter { preferences.isEnabled($0) }.count) of \(items.count) icons shown"
        onChange()
    }

    @objc private func refreshPressed() {
        onRefresh()
    }

    @objc private func resetOrderPressed() {
        preferences.resetCurrentOrder(items)
        items = preferences.ordered(items)
        tableView.reloadData()
        onChange()
    }

    @objc private func donePressed() {
        close()
    }
}
