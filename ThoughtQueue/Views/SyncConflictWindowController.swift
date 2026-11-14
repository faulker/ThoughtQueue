import Cocoa

/// The two sides of a sync conflict as text. A nil side means that copy no longer exists
/// (deleted locally, or deleted remotely).
struct ConflictSides: Equatable {
    var local: String?
    var remote: String?

    /// Reads the local note and the parked remote copy for `key` under `root`. A missing file is
    /// a nil side; any other read failure throws so it can be shown rather than looking like a delete.
    static func load(key: String, root: URL) throws -> ConflictSides {
        let localURL = try SyncEngine.localURL(forKey: key, root: root)
        let remoteURL = SyncState.conflictFileURL(key: key, root: root)
        return ConflictSides(local: try readIfPresent(localURL), remote: try readIfPresent(remoteURL))
    }

    /// The file's text (invalid UTF-8 is replaced, not rejected), or nil when it does not exist.
    private static func readIfPresent(_ url: URL) throws -> String? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return String(decoding: try Data(contentsOf: url), as: UTF8.self)
    }
}

/// Non-modal window that lists open sync conflicts and lets the user settle each one by
/// keeping the local copy, the remote copy, or both.
final class SyncConflictWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = SyncConflictWindowController()

    private let table = NSTableView()
    private let localText = NSTextView()
    private let remoteText = NSTextView()
    private let localHeader = NSTextField(labelWithString: "Local")
    private let remoteHeader = NSTextField(labelWithString: "Remote")
    private let errorLabel = NSTextField(wrappingLabelWithString: "")
    private var buttons: [ThemedButton] = []
    private(set) var conflicts: [SyncState.Conflict] = []
    private var isResolving = false
    private var observer: NSObjectProtocol?

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 820, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Sync Conflicts"
        window.minSize = NSSize(width: 620, height: 340)
        window.level = PreferencesWindowController.level
        window.collectionBehavior.insert(.moveToActiveSpace)
        window.isReleasedWhenClosed = false
        window.center()
        self.init(window: window)
        setupUI()
        observer = NotificationCenter.default.addObserver(
            forName: .syncConflictsDidChange, object: nil, queue: .main
        ) { [weak self] _ in self?.reload() }
    }

    deinit {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }

    /// Reloads the conflict list and brings the window forward, or does nothing when there is
    /// nothing to resolve.
    func present() {
        reload()
        guard !conflicts.isEmpty else { return }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: - UI

    /// Builds the list on the left and the side-by-side texts, buttons and error line on the right.
    private func setupUI() {
        let content = ThemedSurfaceView(frame: .zero)
        window?.contentView = content

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        table.addTableColumn(column)
        table.headerView = nil
        table.dataSource = self
        table.delegate = self
        table.backgroundColor = Theme.surface
        let listScroll = NSScrollView()
        listScroll.documentView = table
        listScroll.hasVerticalScroller = true
        listScroll.translatesAutoresizingMaskIntoConstraints = false
        listScroll.widthAnchor.constraint(equalToConstant: 200).isActive = true

        let sides = NSStackView(views: [pane(localHeader, localText), pane(remoteHeader, remoteText)])
        sides.orientation = .horizontal
        sides.distribution = .fillEqually
        sides.spacing = 12

        let keepLocal = ThemedButton(title: "Keep Local", prominent: false, target: self, action: #selector(keepLocal))
        let keepRemote = ThemedButton(title: "Keep Remote", prominent: false, target: self, action: #selector(keepRemote))
        let keepBoth = ThemedButton(title: "Keep Both", prominent: true, target: self, action: #selector(keepBoth))
        buttons = [keepLocal, keepRemote, keepBoth]
        let buttonRow = NSStackView(views: buttons)
        buttonRow.orientation = .horizontal
        buttonRow.spacing = 8

        errorLabel.font = Theme.body(12)
        errorLabel.textColor = Theme.danger
        errorLabel.isHidden = true

        let right = NSStackView(views: [sides, buttonRow, errorLabel])
        right.orientation = .vertical
        right.alignment = .leading
        right.spacing = 10
        sides.setContentHuggingPriority(.defaultLow, for: .vertical)
        sides.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true

        let root = NSStackView(views: [listScroll, right])
        root.orientation = .horizontal
        root.alignment = .top
        root.spacing = 12
        root.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(root)
        NSLayoutConstraint.activate([
            root.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            root.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            root.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            root.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            listScroll.heightAnchor.constraint(equalTo: root.heightAnchor),
            right.heightAnchor.constraint(equalTo: root.heightAnchor),
        ])
    }

    /// A header label above a read-only, scrollable text view.
    private func pane(_ header: NSTextField, _ text: NSTextView) -> NSView {
        header.font = Theme.body(11, weight: .semibold)
        header.textColor = Theme.accentBorder
        text.isEditable = false
        text.isSelectable = true
        text.font = Theme.body(12.5)
        text.textColor = Theme.textPrimary
        text.backgroundColor = Theme.fieldBackground
        text.textContainerInset = NSSize(width: 6, height: 6)
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView()
        scroll.documentView = text
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        let stack = NSStackView(views: [header, scroll])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        return stack
    }

    // MARK: - Data

    /// Re-reads the open conflicts, keeps the selection when its key survives, and closes the
    /// window when none remain.
    func reload() {
        let selectedKey = selectedConflict?.key
        conflicts = SyncEngine.shared.openConflicts()
        table.reloadData()
        guard !conflicts.isEmpty else {
            window?.close()
            return
        }
        let index = conflicts.firstIndex { $0.key == selectedKey } ?? 0
        table.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        showSelected()
    }

    private var selectedConflict: SyncState.Conflict? {
        let row = table.selectedRow
        return conflicts.indices.contains(row) ? conflicts[row] : nil
    }

    /// Loads both sides of the selected conflict into the text views.
    private func showSelected() {
        guard let conflict = selectedConflict, let root = NoteStore.shared.rootURL else { return }
        do {
            let sides = try ConflictSides.load(key: conflict.key, root: root)
            show(sides.local, in: localText)
            show(sides.remote, in: remoteText)
            setError(nil)
        } catch {
            show(nil, in: localText)
            show(nil, in: remoteText)
            setError("Could not read \(conflict.key): \(error.localizedDescription)")
        }
    }

    /// Shows `text`, or a dimmed "Deleted" when that side no longer exists.
    private func show(_ text: String?, in view: NSTextView) {
        if let text {
            view.string = text
            view.textColor = Theme.textPrimary
        } else {
            view.string = "Deleted"
            view.textColor = Theme.textSecondary
        }
    }

    private func setError(_ message: String?) {
        errorLabel.stringValue = message ?? ""
        errorLabel.isHidden = message == nil
    }

    // MARK: - Actions

    @objc private func keepLocal() { resolve(.keepLocal) }
    @objc private func keepRemote() { resolve(.keepRemote) }
    @objc private func keepBoth() { resolve(.keepBoth) }

    /// Settles the selected conflict. The list refreshes through `.syncConflictsDidChange`;
    /// a failure stays on screen under the buttons.
    private func resolve(_ choice: ConflictResolution) {
        guard let conflict = selectedConflict, !isResolving else { return }
        isResolving = true
        buttons.forEach { $0.isEnabled = false }
        setError(nil)
        Task { @MainActor in
            defer {
                isResolving = false
                buttons.forEach { $0.isEnabled = true }
            }
            do {
                try await SyncEngine.shared.resolveConflict(key: conflict.key, choice: choice)
                reload()
            } catch {
                setError("Could not resolve \(conflict.key): \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { conflicts.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let label = NSTextField(labelWithString: conflicts[row].key)
        label.font = Theme.body(12.5)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingMiddle
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        setError(nil)
        showSelected()
    }
}
