import Cocoa

/// Main window: category sidebar + notes table + note detail pane (three-column split).
final class MainWindowController: NSWindowController {
    static let shared = MainWindowController()

    private let splitVC = NSSplitViewController()
    private let sidebarVC = CategorySidebarViewController()
    private let listVC = NotesListViewController()
    private let detailVC = NoteDetailViewController()

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "ThoughtQueue"
        window.toolbarStyle = .unified
        window.toolbar = NSToolbar()
        window.center()
        window.setFrameAutosaveName("ThoughtQueueMainWindow")
        self.init(window: window)

        sidebarVC.onCategorySelected = { [weak self] selection in
            self?.listVC.show(selection: selection)
        }
        listVC.onNoteSelected = { [weak self] note in
            self?.detailVC.display(note)
        }
        listVC.onNewNote = { [weak self] note in
            self?.detailVC.displayForEditing(note)
        }

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarVC)
        sidebarItem.minimumThickness = 170
        sidebarItem.maximumThickness = 260
        sidebarItem.canCollapse = false

        let listItem = NSSplitViewItem(viewController: listVC)
        listItem.minimumThickness = 240

        let detailItem = NSSplitViewItem(viewController: detailVC)
        detailItem.minimumThickness = 300

        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(listItem)
        splitVC.addSplitViewItem(detailItem)

        window.contentViewController = splitVC
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        sidebarVC.reload()
        sidebarVC.selectAll()
        listVC.show(selection: .all)
    }
}

// MARK: - Sidebar selection

enum SidebarSelection: Equatable {
    case all
    case uncategorized
    case category(String)
}

// MARK: - Category Sidebar

final class CategorySidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onCategorySelected: ((SidebarSelection) -> Void)?

    private let tableView = NSTableView()
    private var categories: [String] = []
    private var reloadWorkItem: DispatchWorkItem?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 560))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("category"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 28
        tableView.style = .sourceList
        tableView.backgroundColor = .clear

        container.addSubview(scrollView)

        let addButton = NSButton(title: "+ Add Category", target: self, action: #selector(addCategory))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.font = .systemFont(ofSize: 13, weight: .medium)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(addButton)

        let gearButton = NSButton(title: "", target: self, action: #selector(openPreferences))
        gearButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: "Preferences")
        gearButton.imagePosition = .imageOnly
        gearButton.bezelStyle = .rounded
        gearButton.controlSize = .large
        gearButton.isBordered = false
        gearButton.toolTip = "Preferences"
        gearButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gearButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            addButton.heightAnchor.constraint(equalToConstant: 32),
            gearButton.centerYAnchor.constraint(equalTo: addButton.centerYAnchor),
            gearButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            gearButton.leadingAnchor.constraint(greaterThanOrEqualTo: addButton.trailingAnchor, constant: 8),
        ])

        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onNotesChanged), name: .notesDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onNotesChanged() {
        let schedule = { [weak self] in
            self?.reloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reload() }
            self?.reloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
        if Thread.isMainThread { schedule() } else { DispatchQueue.main.async { schedule() } }
    }

    func reload() {
        let selectedRow = tableView.selectedRow
        categories = NoteStore.shared.categories()
        tableView.reloadData()
        if selectedRow >= 0 && selectedRow < numberOfRows(in: tableView) {
            tableView.selectRowIndexes(IndexSet(integer: selectedRow), byExtendingSelection: false)
        }
    }

    func selectAll() {
        tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func addCategory() {
        let alert = NSAlert()
        alert.messageText = "New Category"
        alert.informativeText = "Enter a name for the new category folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                _ = NoteStore.shared.createCategory(name)
                reload()
                selectCategory(named: NoteStore.sanitizeCategory(name))
            }
        }
    }

    /// Select the row for a given category name (post-reload), if present.
    private func selectCategory(named name: String?) {
        guard let name = name, let index = categories.firstIndex(of: name) else { return }
        let row = index + 2 // 0 = All, 1 = Uncategorized
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        tableView.scrollRowToVisible(row)
    }

    // Row mapping: 0 = All, 1 = Uncategorized, 2+ = categories.
    func numberOfRows(in tableView: NSTableView) -> Int { categories.count + 2 }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: rowSymbol(row), accessibilityDescription: nil)
        icon.contentTintColor = .controlAccentColor
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let label = NSTextField(labelWithString: rowTitle(row))
        label.font = .systemFont(ofSize: 13)
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [icon, label])
        stack.orientation = .horizontal
        stack.spacing = 6
        return stack
    }

    private func rowTitle(_ row: Int) -> String {
        if row == 0 { return "All" }
        if row == 1 { return Note.uncategorized }
        return categories[row - 2]
    }

    /// SF Symbol for a sidebar row: fixed icons for All/Uncategorized, folder for categories.
    private func rowSymbol(_ row: Int) -> String {
        if row == 0 { return "tray.full" }
        if row == 1 { return "questionmark.folder" }
        return "folder"
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0 else { return }
        if row == 0 { onCategorySelected?(.all) }
        else if row == 1 { onCategorySelected?(.uncategorized) }
        else { onCategorySelected?(.category(categories[row - 2])) }
    }
}

// MARK: - Notes List

final class NotesListViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    var onNoteSelected: ((Note) -> Void)?
    /// Called when a brand-new note is created, so the detail pane can open it for editing.
    var onNewNote: ((Note) -> Void)?

    private let tableView = NSTableView()
    private var notes: [Note] = []
    private var selection: SidebarSelection = .all
    private var reloadWorkItem: DispatchWorkItem?

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 560))

        let scrollView = NSScrollView()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 48
        tableView.style = .inset

        let menu = NSMenu()
        menu.delegate = self
        tableView.menu = menu

        let addButton = NSButton(title: "+ New Note", target: self, action: #selector(addNote))
        addButton.bezelStyle = .rounded
        addButton.controlSize = .large
        addButton.font = .systemFont(ofSize: 13, weight: .medium)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(scrollView)
        container.addSubview(separator)
        container.addSubview(addButton)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),
            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),
            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            addButton.heightAnchor.constraint(equalToConstant: 32),
        ])
        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onNotesChanged), name: .notesDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onNotesChanged() {
        let schedule = { [weak self] in
            self?.reloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reload() }
            self?.reloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
        if Thread.isMainThread { schedule() } else { DispatchQueue.main.async { schedule() } }
    }

    func show(selection: SidebarSelection) {
        self.selection = selection
        reload()
    }

    func reload() {
        _ = view
        switch selection {
        case .all: notes = NoteStore.shared.allNotes()
        case .uncategorized: notes = NoteStore.shared.notes(in: nil)
        case .category(let name): notes = NoteStore.shared.notes(in: name)
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { notes.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let note = notes[row]
        let title = NSTextField(labelWithString: note.title)
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingTail

        let titleRow = NSStackView(views: [title])
        titleRow.orientation = .horizontal
        titleRow.spacing = 5
        if isWorkingDocument(note) {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Working document")
            icon.contentTintColor = .controlAccentColor
            icon.toolTip = "Working document (default capture target)"
            icon.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(icon)
        }

        let subtitle = NSTextField(labelWithString: note.categoryDisplay)
        subtitle.font = .systemFont(ofSize: 11)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [titleRow, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 10, bottom: 4, right: 10)
        return stack
    }

    /// Whether `note` is the configured working document (default capture target).
    private func isWorkingDocument(_ note: Note) -> Bool {
        guard let working = PreferencesManager.shared.workingDocumentURL else { return false }
        return working.standardizedFileURL == note.url.standardizedFileURL
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        guard row >= 0, row < notes.count else { return }
        onNoteSelected?(notes[row])
    }

    /// Create a new empty note in the currently selected category and open it for editing.
    @objc private func addNote() {
        let category: String?
        switch selection {
        case .all, .uncategorized: category = nil
        case .category(let name): category = name
        }
        guard let note = NoteStore.shared.createNote(title: "", body: "", category: category) else { return }
        reload()
        if let idx = notes.firstIndex(of: note) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
            tableView.scrollRowToVisible(idx)
        }
        onNewNote?(note)
    }

    private func clickedNote() -> Note? {
        let row = tableView.clickedRow
        guard row >= 0, row < notes.count else { return nil }
        return notes[row]
    }

    @objc private func deleteClicked() {
        guard let note = clickedNote() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(note.title)\"?"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { _ = NoteStore.shared.delete(note) }
    }

    @objc private func renameClicked() {
        guard let note = clickedNote() else { return }
        let alert = NSAlert()
        alert.messageText = "Rename Note"
        alert.addButton(withTitle: "Rename")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        input.stringValue = note.title
        alert.accessoryView = input
        if alert.runModal() == .alertFirstButtonReturn {
            let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty { _ = NoteStore.shared.rename(note, to: name) }
        }
    }

    @objc private func setWorkingDoc() {
        guard let note = clickedNote() else { return }
        PreferencesManager.shared.workingDocumentURL = note.url
        ToastWindow.show(message: "Working doc: \(note.title)")
    }

    @objc private func unsetWorkingDoc() {
        PreferencesManager.shared.workingDocumentURL = nil
        ToastWindow.show(message: "Working doc cleared")
    }
}

extension NotesListViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let note = clickedNote() else { return }
        let rename = NSMenuItem(title: "Rename", action: #selector(renameClicked), keyEquivalent: "")
        rename.target = self

        let working: NSMenuItem
        if isWorkingDocument(note) {
            working = NSMenuItem(title: "Unset Working Document", action: #selector(unsetWorkingDoc), keyEquivalent: "")
        } else {
            working = NSMenuItem(title: "Set as Working Document", action: #selector(setWorkingDoc), keyEquivalent: "")
        }
        working.target = self

        let delete = NSMenuItem(title: "Delete", action: #selector(deleteClicked), keyEquivalent: "")
        delete.target = self
        menu.addItem(rename)
        menu.addItem(working)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(delete)
    }
}
