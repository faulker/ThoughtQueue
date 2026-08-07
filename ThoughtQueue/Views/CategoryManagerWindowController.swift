import Cocoa

/// Singleton window for adding, renaming, and deleting category folders.
final class CategoryManagerWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = CategoryManagerWindowController()

    private let tableView = NSTableView()
    private var categories: [String] = []
    private var addButton: ThemedButton!
    private var renameButton: ThemedButton!
    private var deleteButton: ThemedButton!

    static let contentSize = NSSize(width: 420, height: 360)

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: CategoryManagerWindowController.contentSize),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Categories"
        window.minSize = NSSize(width: 360, height: 280)
        window.center()
        self.init(window: window)
        setupUI()
        reload()
        NotificationCenter.default.addObserver(
            self, selector: #selector(onNotesChanged), name: .notesDidChange, object: nil
        )
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func setupUI() {
        let content = ThemedSurfaceView(frame: .zero)
        window?.contentView = content

        let title = NSTextField(labelWithString: "Categories")
        title.font = Theme.heading(18)
        title.textColor = Theme.textPrimary
        title.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(title)

        let subtitle = NSTextField(labelWithString: "Folders in your store. Deleting a category moves its notes to Uncategorized.")
        subtitle.font = Theme.body(12)
        subtitle.textColor = Theme.textSecondary
        subtitle.maximumNumberOfLines = 2
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(subtitle)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        column.title = "Name"
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.allowsEmptySelection = true
        tableView.allowsMultipleSelection = false
        tableView.backgroundColor = Theme.surface
        tableView.rowHeight = 28
        tableView.target = self
        tableView.doubleAction = #selector(renameCategory)

        let scroll = NSScrollView()
        scroll.documentView = tableView
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = true
        scroll.backgroundColor = Theme.surface
        content.addSubview(scroll)

        addButton = ThemedButton(title: "Add", prominent: true, target: self, action: #selector(addCategory))
        renameButton = ThemedButton(title: "Rename", prominent: false, target: self, action: #selector(renameCategory))
        deleteButton = ThemedButton(title: "Delete", prominent: false, target: self, action: #selector(deleteCategory))
        content.addSubview(addButton)
        content.addSubview(renameButton)
        content.addSubview(deleteButton)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            subtitle.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            subtitle.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),

            scroll.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 16),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            scroll.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -16),

            addButton.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            addButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
            addButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            renameButton.leadingAnchor.constraint(equalTo: addButton.trailingAnchor, constant: 8),
            renameButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            renameButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),

            deleteButton.leadingAnchor.constraint(equalTo: renameButton.trailingAnchor, constant: 8),
            deleteButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            deleteButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 80),
        ])

        updateButtonState()
    }

    @objc private func onNotesChanged() {
        if Thread.isMainThread {
            reload()
        } else {
            DispatchQueue.main.async { [weak self] in self?.reload() }
        }
    }

    /// Refresh the table from the store, preserving the selected category name when possible.
    private func reload() {
        let selected = selectedCategory()
        categories = NoteStore.shared.categories()
        tableView.reloadData()
        if let selected, let row = categories.firstIndex(of: selected) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
        updateButtonState()
    }

    private func selectedCategory() -> String? {
        let row = tableView.selectedRow
        guard row >= 0, row < categories.count else { return nil }
        return categories[row]
    }

    private func updateButtonState() {
        let hasSelection = selectedCategory() != nil
        renameButton.isEnabled = hasSelection
        deleteButton.isEnabled = hasSelection
    }

    // MARK: - Actions

    /// Prompt for a new category name and create the folder.
    @objc private func addCategory() {
        guard let name = prompt(title: "New Category", message: "Enter a name for the new category folder:", initial: "") else { return }
        guard NoteStore.shared.createCategory(name) else {
            ToastWindow.show(message: "Invalid category name")
            return
        }
        if let safe = NoteStore.sanitizeCategory(name) {
            reload()
            if let row = categories.firstIndex(of: safe) {
                tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
                updateButtonState()
            }
        }
    }

    /// Prompt to rename the selected category.
    @objc private func renameCategory() {
        guard let current = selectedCategory() else { return }
        guard let name = prompt(title: "Rename Category", message: "Enter a new name for \"\(current)\":", initial: current) else { return }
        guard let safe = NoteStore.sanitizeCategory(name) else {
            ToastWindow.show(message: "Invalid category name")
            return
        }
        guard safe != current else { return }
        guard NoteStore.shared.renameCategory(current, to: safe) else {
            ToastWindow.show(message: "Could not rename category")
            return
        }
        reload()
        if let row = categories.firstIndex(of: safe) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            updateButtonState()
        }
    }

    /// Confirm and delete the selected category, moving its notes to Uncategorized.
    @objc private func deleteCategory() {
        guard let current = selectedCategory() else { return }
        let noteCount = NoteStore.shared.notes(in: current).count

        let alert = NSAlert()
        alert.messageText = "Delete \"\(current)\"?"
        if noteCount == 0 {
            alert.informativeText = "This empty category folder will be removed."
        } else {
            let noun = noteCount == 1 ? "note" : "notes"
            alert.informativeText = "\(noteCount) \(noun) will move to Uncategorized, then the folder will be removed."
        }
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        guard NoteStore.shared.deleteCategory(current) else {
            ToastWindow.show(message: "Could not delete category")
            return
        }
        reload()
    }

    /// Shared name prompt used by Add and Rename.
    private func prompt(title: String, message: String, initial: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = initial
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        return input.stringValue
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { categories.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let name = categories[row]
        let tint = Theme.categoryTint(for: name)

        let swatch = NSView()
        swatch.wantsLayer = true
        swatch.layer?.backgroundColor = tint.foreground.cgColor
        swatch.layer?.cornerRadius = 4
        swatch.translatesAutoresizingMaskIntoConstraints = false
        swatch.widthAnchor.constraint(equalToConstant: 10).isActive = true
        swatch.heightAnchor.constraint(equalToConstant: 10).isActive = true

        let label = NSTextField(labelWithString: name)
        label.font = Theme.body(13, weight: .medium)
        label.textColor = Theme.textPrimary
        label.lineBreakMode = .byTruncatingTail

        let count = NoteStore.shared.notes(in: name).count
        let countLabel = NSTextField(labelWithString: "\(count)")
        countLabel.font = Theme.body(12)
        countLabel.textColor = Theme.textSecondary
        countLabel.setContentHuggingPriority(.required, for: .horizontal)

        let stack = NSStackView(views: [swatch, label, countLabel])
        stack.orientation = .horizontal
        stack.spacing = 8
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        updateButtonState()
    }
}
