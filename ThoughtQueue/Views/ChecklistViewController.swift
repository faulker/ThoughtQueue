import Cocoa

/// The editor for a "list note": a real checkbox list rather than a markdown document.
///
/// A list note is still a plain `.md` file of `- [ ]` lines on disk, but in this view it is never
/// text to be edited as markdown. Every box is always clickable, and each item's text is its own
/// field, so there is no document-wide edit mode to enter or leave.
///
/// Rows are a stack of live controls rather than an `NSTableView`: table rows are recycled, and a
/// recycled row takes the shared field editor with it, losing an in-progress edit when a row
/// scrolls out of view. Focus management is the whole feature here, so reuse would buy only bugs.
/// `PopoverController` already builds its note list the same way.
final class ChecklistViewController: NSViewController, NSTextFieldDelegate {

    /// Why the body changed, so the owner can decide how urgently to persist it. `text` is a
    /// keystroke (debounced); `textCommitted` is the user leaving the field, which is a real
    /// commit point and writes at once.
    enum CommitReason { case checkbox, structure, text, textCommitted }

    /// Called whenever the body changes and should be written.
    var onCommit: ((_ body: String, _ reason: CommitReason) -> Void)?

    /// Above this many source lines the note falls back to rendered markdown: roughly a thousand
    /// autolayout subviews is where building the stack stops feeling instant.
    static let maxRows = 400

    private(set) var rows: [TaskList.Row] = []
    private var rowViews: [ChecklistRowView] = []

    private let stackView = NSStackView()
    private let addRow = ChecklistAddRowView()
    let scrollView = NSScrollView()

    /// Guards against re-entrancy: removing a field inside its own end-editing callback is a
    /// classic AppKit crash, and rebuilding fires those callbacks.
    private var isRebuilding = false
    /// Set when an external change arrives mid-edit, applied once the field commits.
    private var needsReloadAfterEditing = false

    override func loadView() {
        let container = ThemedSurfaceView()

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 2
        stackView.edgeInsets = NSEdgeInsets(top: 8, left: 0, bottom: 8, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: flipped.topAnchor),
            stackView.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor),
        ])

        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = flipped
        flipped.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        container.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])

        addRow.onAdd = { [weak self] in self?.appendItem() }
        self.view = container
    }

    // MARK: - Loading

    /// Rebuild every row. Commits any pending edit and drops first responder first, so no field
    /// editor is torn out from under the user.
    func load(rows newRows: [TaskList.Row]) {
        _ = view
        isRebuilding = true
        defer { isRebuilding = false }

        if view.window?.firstResponder is NSText { view.window?.makeFirstResponder(nil) }

        rows = newRows
        rowViews.forEach { $0.removeFromSuperview() }
        addRow.removeFromSuperview()
        rowViews = []

        for (index, row) in rows.enumerated() {
            let rowView = makeRowView(for: row, at: index)
            rowViews.append(rowView)
            stackView.addArrangedSubview(rowView)
            rowView.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
        }

        stackView.addArrangedSubview(addRow)
        addRow.widthAnchor.constraint(equalTo: stackView.widthAnchor).isActive = true
    }

    private func makeRowView(for row: TaskList.Row, at index: Int) -> ChecklistRowView {
        let rowView: ChecklistRowView
        switch row.kind {
        case .task:
            rowView = ChecklistItemRowView()
        case .heading:
            rowView = ChecklistHeadingRowView()
        case .blank:
            rowView = ChecklistBlankRowView()
        case .other:
            rowView = ChecklistOtherRowView()
        }
        rowView.owner = self
        rowView.index = index
        rowView.configure(with: row)
        rowView.field?.delegate = self
        return rowView
    }

    /// Row indices shift after an insert or delete; renumber rather than rebuilding.
    private func renumber() {
        for (index, rowView) in rowViews.enumerated() { rowView.index = index }
    }

    // MARK: - Focus

    func focusFirstEditableRow() {
        _ = view
        guard let index = TaskList.nextEditableIndex(atOrAfter: 0, in: rows) else { return }
        focus(row: index, offset: rows[index].text.count)
    }

    private func focus(row index: Int, offset: Int) {
        guard rowViews.indices.contains(index), let field = rowViews[index].field else { return }
        guard let window = view.window else { return }
        window.makeFirstResponder(field)
        if let editor = field.currentEditor() {
            let clamped = min(max(offset, 0), (editor.string as NSString).length)
            editor.selectedRange = NSRange(location: clamped, length: 0)
        }
    }

    /// The row whose field currently holds the caret.
    private var focusedIndex: Int? {
        guard let responder = view.window?.firstResponder else { return nil }
        for (index, rowView) in rowViews.enumerated() {
            guard let field = rowView.field else { continue }
            if responder === field || responder === field.currentEditor() { return index }
        }
        return nil
    }

    // MARK: - Mutation

    private func apply(_ edit: TaskList.Edit, reason: CommitReason) {
        rows = edit.rows
        load(rows: rows)
        commit(reason)
        focus(row: edit.focusRow, offset: edit.focusOffset)
    }

    private func commit(_ reason: CommitReason) {
        onCommit?(TaskList.body(from: rows), reason)
    }

    /// Toggle one row's checkbox and write immediately. Used by clicks, Cmd+Return and tests.
    @discardableResult
    func toggleRow(at index: Int) -> Bool {
        guard rows.indices.contains(index), rows[index].isTask else { return false }
        rows = TaskList.settingChecked(!rows[index].checked, at: index, in: rows)
        rowViews[safe: index]?.configure(with: rows[index])
        commit(.checkbox)
        return true
    }

    /// A checkbox in a row view was clicked. Writes immediately, with no toast.
    func checkboxToggledFromRow(at index: Int, to checked: Bool) {
        guard rows.indices.contains(index) else { return }
        rows = TaskList.settingChecked(checked, at: index, in: rows)
        rowViews[safe: index]?.configure(with: rows[index])
        commit(.checkbox)
    }

    private func appendItem() {
        let anchor = TaskList.appendAnchor(in: rows)
        apply(TaskList.insertingTask(after: anchor, in: rows), reason: .structure)
    }

    /// Pull the focused field's text into the model. Returns true when something changed.
    @discardableResult
    func flushPendingEdit() -> Bool {
        guard let index = focusedIndex, let field = rowViews[safe: index]?.field else { return false }
        let text = field.currentEditor()?.string ?? field.stringValue
        guard text != rows[index].text else { return false }
        rows = TaskList.settingText(text, at: index, in: rows)
        return true
    }

    // MARK: - Text field delegate

    func controlTextDidChange(_ obj: Notification) {
        guard !isRebuilding, let field = obj.object as? NSTextField else { return }
        guard let index = rowViews.firstIndex(where: { $0.field === field }) else { return }
        rows = TaskList.settingText(field.stringValue, at: index, in: rows)
        onCommit?(TaskList.body(from: rows), .text)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard !isRebuilding, let field = obj.object as? NSTextField else { return }
        guard let index = rowViews.firstIndex(where: { $0.field === field }) else { return }
        if field.stringValue != rows[index].text {
            rows = TaskList.settingText(field.stringValue, at: index, in: rows)
            commit(.textCommitted)
        }
        if needsReloadAfterEditing {
            needsReloadAfterEditing = false
            load(rows: rows)
        }
    }

    /// All checklist keyboard behavior. Returning true stops AppKit's default handling.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let field = control as? NSTextField,
              let index = rowViews.firstIndex(where: { $0.field === field }) else { return false }

        let range = textView.selectedRange()
        let length = (textView.string as NSString).length
        let atStart = range.location == 0 && range.length == 0
        let atEnd = range.location == length && range.length == 0

        // Keep the model in step with what is on screen before restructuring around it.
        rows = TaskList.settingText(textView.string, at: index, in: rows)

        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            if rows[index].text.isEmpty, rows[index].isTask {
                // An empty item means "end the list", the row-shaped form of clearMarker.
                guard rows.filter(\.isTask).count > 1 else { return true }
                apply(TaskList.deletingRow(at: index, in: rows), reason: .structure)
            } else if atEnd {
                apply(TaskList.insertingTask(after: index, in: rows), reason: .structure)
            } else {
                apply(TaskList.splittingTask(at: index, offset: range.location, in: rows), reason: .structure)
            }
            return true

        case #selector(NSResponder.deleteBackward(_:)):
            guard atStart else { return false }
            if rows[index].text.isEmpty {
                guard rows.count > 1 else { return true }
                apply(TaskList.deletingRow(at: index, in: rows), reason: .structure)
                return true
            }
            let merged = TaskList.mergingRowIntoPrevious(at: index, in: rows)
            guard merged.rows != rows else { return false }
            apply(merged, reason: .structure)
            return true

        case #selector(NSResponder.insertTab(_:)):
            guard let next = TaskList.nextEditableIndex(atOrAfter: index + 1, in: rows) else {
                view.window?.makeFirstResponder(addRow)
                return true
            }
            focus(row: next, offset: rows[next].text.count)
            return true

        case #selector(NSResponder.insertBacktab(_:)):
            guard let previous = TaskList.previousEditableIndex(before: index, in: rows) else { return false }
            focus(row: previous, offset: rows[previous].text.count)
            return true

        case #selector(NSResponder.moveUp(_:)):
            guard let previous = TaskList.previousEditableIndex(before: index, in: rows) else { return true }
            focus(row: previous, offset: min(range.location, rows[previous].text.count))
            return true

        case #selector(NSResponder.moveDown(_:)):
            guard let next = TaskList.nextEditableIndex(atOrAfter: index + 1, in: rows) else { return true }
            focus(row: next, offset: min(range.location, rows[next].text.count))
            return true

        case #selector(NSResponder.cancelOperation(_:)):
            view.window?.makeFirstResponder(view)
            return true

        default:
            return false
        }
    }

    // MARK: - External changes

    /// Reload from a body changed on disk, deferring while a field is being edited so the field
    /// editor is never yanked away mid-keystroke.
    func reload(from body: String, preserveFocus: Bool = true) {
        let focused = preserveFocus ? focusedIndex : nil
        if focusedIndex != nil, view.window?.firstResponder is NSText {
            rows = TaskList.rows(from: body)
            needsReloadAfterEditing = true
            return
        }
        let offset = scrollView.contentView.bounds.origin
        load(rows: TaskList.rows(from: body))
        scrollView.contentView.scroll(to: offset)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        if let focused { focus(row: min(focused, rows.count - 1), offset: 0) }
    }

    // MARK: - Test seams

    /// Focus a row's field directly. Tests drive the keyboard paths through this rather than
    /// synthesizing mouse and key events.
    func focusRowForTesting(_ index: Int, offset: Int) {
        focus(row: index, offset: offset)
    }

    func fieldForTesting(at index: Int) -> NSTextField? {
        rowViews[safe: index]?.field
    }

    /// Cmd+Return and Shift+Cmd+L route here.
    @discardableResult
    func toggleFocusedRow() -> Bool {
        guard let index = focusedIndex else { return false }
        return toggleRow(at: index)
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
