import Cocoa

/// One row in the navigator's tree: either a category group (which owns note children) or a
/// note. A reference type on purpose: NSOutlineView tracks its items by object identity, and
/// value types (including `Note`) get boxed anew on every data source call, which breaks
/// `row(forItem:)` and `expandItem(_:)`.
final class NoteNavigatorNode {
    let category: String?
    let note: Note?
    var children: [NoteNavigatorNode] = []

    init(category: String) {
        self.category = category
        self.note = nil
    }

    init(note: Note) {
        self.note = note
        self.category = nil
    }

    var isGroup: Bool { note == nil }
}

/// The note window's left-hand navigation panel: a source-list tree of every note grouped by
/// category, with a search field on top. Selecting a note reports it through `onNoteSelected`
/// so the owning window can switch the editor over to it; the panel never opens windows itself.
///
/// The tree is rebuilt from the store on every reload (nodes are throwaway), so group expansion
/// and the highlighted row are re-applied afterward from `collapsedGroups` / `highlightedURL`
/// rather than relying on AppKit's per-item state.
final class NoteNavigatorViewController: NSViewController, NSOutlineViewDataSource, NSOutlineViewDelegate, NSSearchFieldDelegate {
    /// Called when the user picks a note in the list (never for programmatic selection).
    var onNoteSelected: ((Note) -> Void)?

    private let outlineView = NSOutlineView()
    private let searchField = NSSearchField()
    private var groups: [NoteNavigatorNode] = []
    /// Category names the user collapsed, so a reload doesn't re-expand them behind their back.
    private var collapsedGroups: Set<String> = []
    private var reloadWorkItem: DispatchWorkItem?
    private var selectWorkItem: DispatchWorkItem?
    /// True while we expand/select rows ourselves, so those changes aren't mistaken for user
    /// actions (which would re-fire `onNoteSelected` or record a manual collapse).
    private var isProgrammatic = false
    /// The note currently shown in the editor, tracked by URL because reloads re-sort the tree.
    private(set) var highlightedURL: URL?
    private var query = ""

    private static let groupRowHeight: CGFloat = 24
    private static let noteRowHeight: CGFloat = 26

    override func loadView() {
        let width = PreferencesManager.shared.noteNavigatorWidth
        let container = ThemedSurfaceView(frame: NSRect(x: 0, y: 0, width: width, height: 520))

        searchField.placeholderString = "Search notes"
        searchField.delegate = self
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        // Deliberately not themed: a custom font throws off NSSearchFieldCell's vertical
        // centering, which assumes system font metrics at this control size.
        searchField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(searchField)

        let scrollView = NSScrollView()
        scrollView.documentView = outlineView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface
        container.addSubview(scrollView)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("note"))
        outlineView.addTableColumn(column)
        outlineView.outlineTableColumn = column
        outlineView.headerView = nil
        outlineView.dataSource = self
        outlineView.delegate = self
        outlineView.style = .sourceList
        outlineView.backgroundColor = Theme.surface
        outlineView.floatsGroupRows = false
        outlineView.indentationPerLevel = 12
        outlineView.autoresizesOutlineColumn = false

        let menu = NSMenu()
        menu.delegate = self
        outlineView.menu = menu

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 8),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onNotesChanged), name: .notesDidChange, object: nil)
    }

    /// Load the tree as soon as the view exists rather than waiting for the panel to be
    /// revealed, so the list is never empty on screen no matter what put it there.
    override func viewDidLoad() {
        super.viewDidLoad()
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Rows currently in the outline (groups plus their expanded notes). Read by tests.
    var rowCount: Int { outlineView.numberOfRows }

    /// Rebuild from the store, debounced so a burst of saves costs one tree walk.
    @objc private func onNotesChanged() {
        let schedule = { [weak self] in
            self?.reloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reload() }
            self?.reloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
        if Thread.isMainThread { schedule() } else { DispatchQueue.main.async { schedule() } }
    }

    // MARK: - Loading

    /// Rebuild the tree from the store, then restore expansion and the highlighted row.
    func reload() {
        _ = view
        groups = buildGroups()
        outlineView.reloadData()
        applyExpansion()
        selectHighlightedRow()
    }

    /// Group every note by category (Uncategorized last), dropping empty groups and applying
    /// the current search query. Notes keep the store's newest-modified-first order unless a
    /// query is active, in which case fuzzy relevance wins.
    private func buildGroups() -> [NoteNavigatorNode] {
        let store = NoteStore.shared
        var names: [String?] = store.categories()
        names.append(nil) // Uncategorized sorts last

        return names.compactMap { category in
            var notes = store.notes(in: category)
            if !query.isEmpty {
                notes = FuzzySearch.rank(notes: notes, query: query)
            }
            guard !notes.isEmpty else { return nil }
            let group = NoteNavigatorNode(category: category ?? Note.uncategorized)
            group.children = notes.map { NoteNavigatorNode(note: $0) }
            return group
        }
    }

    /// Expand groups the user hasn't collapsed. While searching, every matching group is
    /// expanded so hits are never hidden behind a collapsed header.
    private func applyExpansion() {
        isProgrammatic = true
        for group in groups {
            let name = group.category ?? ""
            if query.isEmpty && collapsedGroups.contains(name) {
                outlineView.collapseItem(group)
            } else {
                outlineView.expandItem(group)
            }
        }
        isProgrammatic = false
    }

    // MARK: - Selection

    /// Select the row for `note` without firing `onNoteSelected`. Used when the window switches
    /// notes for reasons other than a click here (retarget, rename/move, reload re-sort).
    func highlight(note: Note) {
        _ = view
        highlightedURL = note.url.standardizedFileURL
        selectHighlightedRow()
    }

    /// Move the table selection onto `highlightedURL`, expanding its group first so it has a
    /// row at all. Deselects when the note isn't in the current (possibly filtered) tree.
    private func selectHighlightedRow() {
        guard let url = highlightedURL,
              let group = groups.first(where: { $0.children.contains { $0.note?.url.standardizedFileURL == url } }),
              let node = group.children.first(where: { $0.note?.url.standardizedFileURL == url })
        else {
            isProgrammatic = true
            outlineView.deselectAll(nil)
            isProgrammatic = false
            return
        }

        isProgrammatic = true
        outlineView.expandItem(group)
        let row = outlineView.row(forItem: node)
        if row >= 0 {
            outlineView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outlineView.scrollRowToVisible(row)
        }
        isProgrammatic = false
    }

    func outlineViewSelectionDidChange(_ notification: Notification) {
        guard !isProgrammatic,
              let node = outlineView.item(atRow: outlineView.selectedRow) as? NoteNavigatorNode,
              let note = node.note,
              note.url.standardizedFileURL != highlightedURL
        else { return }

        // Arrow-keying down the list would otherwise save and reload a file per keystroke.
        selectWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.onNoteSelected?(note) }
        selectWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: item)
    }

    // MARK: - Search

    func controlTextDidChange(_ obj: Notification) {
        guard obj.object as? NSSearchField === searchField else { return }
        query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        reload()
    }

    // MARK: - Data source

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        guard let node = item as? NoteNavigatorNode else { return groups.count }
        return node.children.count
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        guard let node = item as? NoteNavigatorNode else { return groups[index] }
        return node.children[index]
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        (item as? NoteNavigatorNode)?.children.isEmpty == false
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        (item as? NoteNavigatorNode)?.isGroup ?? false
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        (item as? NoteNavigatorNode)?.isGroup == false
    }

    func outlineView(_ outlineView: NSOutlineView, heightOfRowByItem item: Any) -> CGFloat {
        let isGroup = (item as? NoteNavigatorNode)?.isGroup ?? false
        return isGroup ? Self.groupRowHeight : Self.noteRowHeight
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        guard let node = item as? NoteNavigatorNode else { return nil }
        if let note = node.note { return noteRow(for: note) }
        return groupRow(named: node.category ?? "")
    }

    /// A category header row: small caps label in the design's sage accent.
    private func groupRow(named name: String) -> NSView {
        let label = NSTextField(labelWithString: name.uppercased())
        label.font = Theme.body(10.5, weight: .semibold)
        label.textColor = Theme.accentBorder
        label.lineBreakMode = .byTruncatingTail

        let stack = NSStackView(views: [label])
        stack.orientation = .horizontal
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 4, bottom: 0, right: 6)
        return stack
    }

    /// A note row: just the title (with a working-document badge). The category is already the
    /// group header above it, so repeating it per-row is redundant here (unlike the popover/main
    /// window lists, which show notes across every category at once).
    private func noteRow(for note: Note) -> NSView {
        let title = NSTextField(labelWithString: note.title)
        title.font = Theme.body(13, weight: .medium)
        title.textColor = Theme.textPrimary
        title.lineBreakMode = .byTruncatingTail

        let titleRow = NSStackView(views: [title])
        titleRow.orientation = .horizontal
        titleRow.spacing = 5
        if isWorkingDocument(note) {
            let icon = NSImageView()
            icon.image = NSImage(systemSymbolName: "tray.and.arrow.down.fill", accessibilityDescription: "Working document")
            icon.contentTintColor = Theme.accent
            icon.toolTip = "Working document (default capture target)"
            icon.setContentHuggingPriority(.required, for: .horizontal)
            titleRow.addArrangedSubview(icon)
        }

        titleRow.edgeInsets = NSEdgeInsets(top: 3, left: 4, bottom: 3, right: 6)
        return titleRow
    }

    /// Whether `note` is the configured working document (default capture target).
    private func isWorkingDocument(_ note: Note) -> Bool {
        guard let working = PreferencesManager.shared.workingDocumentURL else { return false }
        return working.standardizedFileURL == note.url.standardizedFileURL
    }

    /// The note under the right-click (or nil when the click landed on a group / empty area).
    private func clickedNote() -> Note? {
        let row = outlineView.clickedRow
        guard row >= 0, let node = outlineView.item(atRow: row) as? NoteNavigatorNode else { return nil }
        return node.note
    }

    /// Designate the clicked note as the working document (default quick-capture sink).
    @objc private func setWorkingDoc() {
        guard let note = clickedNote() else { return }
        PreferencesManager.shared.workingDocumentURL = note.url
        ToastWindow.show(message: "Working doc: \(note.title)")
    }

    /// Clear the working-document preference.
    @objc private func unsetWorkingDoc() {
        PreferencesManager.shared.workingDocumentURL = nil
        ToastWindow.show(message: "Working doc cleared")
    }

    // MARK: - Expansion tracking

    func outlineViewItemDidCollapse(_ notification: Notification) {
        guard !isProgrammatic, let node = notification.userInfo?["NSObject"] as? NoteNavigatorNode,
              let name = node.category else { return }
        collapsedGroups.insert(name)
    }

    func outlineViewItemDidExpand(_ notification: Notification) {
        guard !isProgrammatic, let node = notification.userInfo?["NSObject"] as? NoteNavigatorNode,
              let name = node.category else { return }
        collapsedGroups.remove(name)
    }
}

extension NoteNavigatorViewController: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let note = clickedNote() else { return }
        let working: NSMenuItem
        if isWorkingDocument(note) {
            working = NSMenuItem(title: "Unset Working Document", action: #selector(unsetWorkingDoc), keyEquivalent: "")
        } else {
            working = NSMenuItem(title: "Set as Working Document", action: #selector(setWorkingDoc), keyEquivalent: "")
        }
        working.target = self
        menu.addItem(working)
    }
}
