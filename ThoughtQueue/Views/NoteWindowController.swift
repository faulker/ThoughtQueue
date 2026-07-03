import Cocoa

/// A standalone window for creating, viewing, and editing a single note. This is the one
/// and only note window: "New Note" opens it in edit mode on a freshly created note, and
/// clicking an existing note opens it in view mode (rendered markdown). An eye/pencil toggle
/// in the header switches between read-only view and raw markdown edit modes. The title field
/// and category dropdown sit inline in the header and are always editable, independent of the
/// body's view/edit mode. Edits autosave on mode switch, focus loss, and window close.
///
/// One window is kept per note URL: opening a note that already has a window brings the
/// existing window forward instead of spawning a duplicate. When the note is renamed or
/// moved (its URL changes), the registry key is kept in sync.
final class NoteWindowController: NSWindowController, NSWindowDelegate {
    /// Live windows keyed by standardized note URL, so we reuse rather than duplicate.
    private static var open: [URL: NoteWindowController] = [:]

    private var noteURL: URL
    private let editor: NoteEditorViewController

    /// Open (or focus) a window for an existing note, starting in view mode.
    static func show(note: Note) {
        let key = note.url.standardizedFileURL
        if let existing = open[key] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        present(note: note, startInEditMode: false)
    }

    /// Create a brand-new note (empty by default, or pre-filled with `body`) and open the
    /// same editor window in edit mode. Used by "New Note" and detailed capture so there is a
    /// single note window for both creating and viewing/editing.
    @discardableResult
    static func showNew(body: String = "", category: String? = nil) -> Note? {
        guard let note = NoteStore.shared.createNote(title: "", body: body, category: category) else {
            ToastWindow.show(message: "Failed to create note")
            return nil
        }
        present(note: note, startInEditMode: true)
        return note
    }

    /// Build, register, and front a window for `note`.
    private static func present(note: Note, startInEditMode: Bool) {
        let key = note.url.standardizedFileURL
        let wc = NoteWindowController(note: note, startInEditMode: startInEditMode)
        open[key] = wc
        wc.showWindow(nil)
        wc.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(note: Note, startInEditMode: Bool) {
        self.noteURL = note.url.standardizedFileURL
        self.editor = NoteEditorViewController(note: note, startInEditMode: startInEditMode)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = note.title
        window.contentViewController = editor
        window.center()
        super.init(window: window)
        window.delegate = self

        // Keep the registry key and window title in sync when the note is renamed/moved.
        editor.onNoteChanged = { [weak self] newNote, oldKey in
            guard let self else { return }
            let newKey = newNote.url.standardizedFileURL
            if NoteWindowController.open[oldKey] === self {
                NoteWindowController.open[oldKey] = nil
            }
            self.noteURL = newKey
            NoteWindowController.open[newKey] = self
            self.window?.title = newNote.title
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /// Persist any pending edit and drop our registry entry when the window closes.
    func windowWillClose(_ notification: Notification) {
        editor.saveIfDirty()
        NoteWindowController.open[noteURL] = nil
    }
}

/// An NSTextView that, while in read-only (rendered markdown) view mode, switches into edit
/// mode when the user tries to type, paste, or double-click, instead of doing nothing. A
/// single click still just selects/positions, so text stays readable and selectable.
final class ModeSwitchingTextView: NSTextView {
    var onActivateEditing: (() -> Void)?

    /// Typing while read-only activates editing, then the keystroke is applied.
    override func keyDown(with event: NSEvent) {
        if !isEditable, let activate = onActivateEditing {
            activate()
            super.keyDown(with: event) // now editable: the typed character lands
        } else {
            super.keyDown(with: event)
        }
    }

    /// A double-click while read-only activates editing; a single click is left to select.
    override func mouseDown(with event: NSEvent) {
        if !isEditable, event.clickCount >= 2, let activate = onActivateEditing {
            activate()
        }
        super.mouseDown(with: event)
    }

    /// Pasting while read-only activates editing so the paste has somewhere to go.
    override func paste(_ sender: Any?) {
        if !isEditable { onActivateEditing?() }
        super.paste(sender)
    }
}

/// The view controller inside a `NoteWindowController`: an editable title field and a
/// category dropdown inline in the header, above a text area that either renders markdown
/// (view) or exposes the raw markdown for editing (edit). Title/category changes rename/move
/// the underlying file.
final class NoteEditorViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate {
    private var note: Note

    /// Called after the note is renamed or moved (its URL changed). Passes the new note and
    /// the previous standardized URL so the owning window can re-key itself.
    var onNoteChanged: ((_ newNote: Note, _ oldKey: URL) -> Void)?

    private var titleField: NSTextField!
    private var categoryPopup: NSPopUpButton!
    private var scrollView: NSScrollView!
    private var textView: ModeSwitchingTextView!
    private var toggleButton: NSButton!

    private var isEditing = false
    /// True when the raw text has unsaved changes since the last save/load.
    private var isDirty = false
    /// Whether the window should open straight into edit mode (new notes) vs view mode.
    private let startInEditMode: Bool

    /// Popup title for the "no category" (store root) choice.
    private static let uncategorizedItem = Note.uncategorized
    /// Popup title that triggers the new-category prompt.
    private static let newCategoryItem = "New Category\u{2026}"

    init(note: Note, startInEditMode: Bool = false) {
        self.note = note
        self.startInEditMode = startInEditMode
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))

        titleField = NSTextField(string: note.title)
        titleField.font = .systemFont(ofSize: 15, weight: .semibold)
        titleField.lineBreakMode = .byTruncatingTail
        titleField.isBordered = true
        titleField.isBezeled = true
        titleField.bezelStyle = .roundedBezel
        titleField.placeholderString = "Title"
        titleField.delegate = self
        titleField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        titleField.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(titleField)

        // Category dropdown sits inline to the right of the title (fix #2).
        categoryPopup = NSPopUpButton(frame: .zero, pullsDown: false)
        categoryPopup.target = self
        categoryPopup.action = #selector(categoryChanged(_:))
        categoryPopup.toolTip = "Category"
        categoryPopup.setContentHuggingPriority(.defaultHigh, for: .horizontal)
        categoryPopup.setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
        categoryPopup.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(categoryPopup)

        toggleButton = NSButton(title: "", target: self, action: #selector(toggleMode))
        toggleButton.bezelStyle = .rounded
        toggleButton.imagePosition = .imageOnly
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleButton)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView = ModeSwitchingTextView()
        textView.delegate = self
        textView.onActivateEditing = { [weak self] in self?.beginEditingFromView() }
        textView.font = PreferencesManager.shared.editorFont
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            categoryPopup.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            categoryPopup.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),

            toggleButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: categoryPopup.trailingAnchor, constant: 8),
            toggleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: categoryPopup.bottomAnchor, constant: 10),
            scrollView.topAnchor.constraint(greaterThanOrEqualTo: titleField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onEditorFontChanged), name: .editorFontDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildCategoryMenu()
        if startInEditMode {
            editRaw()
        } else {
            renderMarkdown() // default to view mode
        }
        updateToggle()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // New notes open ready to type; put the cursor in the body.
        if startInEditMode { view.window?.makeFirstResponder(textView) }
    }

    // MARK: - Title

    /// Commit a title edit on focus loss (Enter/Tab or clicking away).
    func controlTextDidEndEditing(_ obj: Notification) {
        guard obj.object as? NSTextField === titleField else { return }
        commitTitleIfNeeded()
    }

    /// Rename the note file to match the title field if it changed. No-op when unchanged or
    /// empty. Called both on focus loss and before a category change, so a pending title edit
    /// is never dropped when the category dropdown is used (fix #1).
    private func commitTitleIfNeeded() {
        let typed = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty, typed != note.title else {
            titleField.stringValue = note.title // revert empty/no-op edits
            return
        }
        saveIfDirty()
        let oldKey = note.url.standardizedFileURL
        guard let renamed = NoteStore.shared.rename(note, to: typed) else {
            titleField.stringValue = note.title
            ToastWindow.show(message: "Rename failed")
            return
        }
        applyNoteChange(renamed, oldKey: oldKey)
        ToastWindow.show(message: "Renamed")
    }

    // MARK: - Category

    /// Populate the category dropdown from the store and select the note's current category.
    private func rebuildCategoryMenu() {
        categoryPopup.removeAllItems()
        categoryPopup.addItem(withTitle: Self.uncategorizedItem)
        let categories = NoteStore.shared.categories()
        if !categories.isEmpty {
            categoryPopup.addItems(withTitles: categories)
        }
        categoryPopup.menu?.addItem(.separator())
        categoryPopup.addItem(withTitle: Self.newCategoryItem)
        categoryPopup.selectItem(withTitle: note.category ?? Self.uncategorizedItem)
    }

    /// Move the note to the chosen category, or prompt for a new one. Any pending title edit
    /// is committed first so switching category never reverts the title (fix #1).
    @objc private func categoryChanged(_ sender: NSPopUpButton) {
        guard let chosen = sender.titleOfSelectedItem else { return }

        if chosen == Self.newCategoryItem {
            commitTitleIfNeeded()
            promptNewCategory()
            return
        }

        let target: String? = (chosen == Self.uncategorizedItem) ? nil : chosen
        commitTitleIfNeeded()
        guard target != note.category else {
            rebuildCategoryMenu()
            return
        }
        performMove(to: target)
    }

    /// Ask for a new category name, create it, then move the note into it.
    private func promptNewCategory() {
        let alert = NSAlert()
        alert.messageText = "New Category"
        alert.informativeText = "Enter a name for the new category folder:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        alert.accessoryView = input
        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            rebuildCategoryMenu() // reset selection back to current
            return
        }
        let name = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let safe = NoteStore.sanitizeCategory(name) else {
            rebuildCategoryMenu()
            ToastWindow.show(message: "Invalid category name")
            return
        }
        performMove(to: safe)
    }

    /// Move the note file into `category` (nil = Uncategorized) and sync UI/state.
    private func performMove(to category: String?) {
        saveIfDirty()
        let oldKey = note.url.standardizedFileURL
        guard let moved = NoteStore.shared.move(note, to: category) else {
            rebuildCategoryMenu()
            ToastWindow.show(message: "Move failed")
            return
        }
        applyNoteChange(moved, oldKey: oldKey)
        ToastWindow.show(message: category == nil ? "Moved to Uncategorized" : "Moved to \(category!)")
    }

    /// Adopt a renamed/moved note: update state, UI fields, and notify the owning window.
    private func applyNoteChange(_ newNote: Note, oldKey: URL) {
        note = newNote
        titleField.stringValue = newNote.title
        rebuildCategoryMenu()
        onNoteChanged?(newNote, oldKey)
    }

    // MARK: - Mode toggle

    /// Flip between rendered-markdown view mode and raw-markdown edit mode.
    @objc private func toggleMode() {
        if isEditing {
            saveIfDirty()
            renderMarkdown()
        } else {
            editRaw()
            view.window?.makeFirstResponder(textView)
        }
        updateToggle()
    }

    /// Switch from view mode into edit mode in response to typing/paste/double-click.
    private func beginEditingFromView() {
        guard !isEditing else { return }
        editRaw()
        view.window?.makeFirstResponder(textView)
        updateToggle()
    }

    /// Set the toggle button's icon/tooltip to reflect the action it performs next.
    private func updateToggle() {
        let symbol = isEditing ? "eye" : "square.and.pencil"
        let tip = isEditing ? "View" : "Edit"
        toggleButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        toggleButton.toolTip = tip
    }

    private func renderMarkdown() {
        isEditing = false
        isDirty = false
        textView.isEditable = false
        textView.isSelectable = true
        let body = NoteStore.shared.body(of: note)
        let attributed = MarkdownRenderer.render(body, baseFont: PreferencesManager.shared.editorFont)
        textView.textStorage?.setAttributedString(attributed)
    }

    private func editRaw() {
        isEditing = true
        isDirty = false
        textView.isEditable = true
        // Pin the editor font: setting `string` adopts current typing attributes, which
        // after a markdown render may carry a larger heading font. Reset them so raw
        // text stays consistent.
        let font = PreferencesManager.shared.editorFont
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.string = NoteStore.shared.body(of: note)
        textView.font = font
    }

    /// Re-apply a changed editor font to whichever mode is active.
    @objc private func onEditorFontChanged() {
        textView.font = PreferencesManager.shared.editorFont
        if !isEditing { renderMarkdown() }
    }

    // MARK: - Autosave

    func textDidChange(_ notification: Notification) {
        if isEditing { isDirty = true }
    }

    func textDidEndEditing(_ notification: Notification) {
        saveIfDirty()
    }

    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveIfDirty()
    }

    /// Persist the current raw text if we're editing and have unsaved changes.
    func saveIfDirty() {
        guard isEditing, isDirty else { return }
        _ = NoteStore.shared.updateBody(of: note, body: textView.string)
        isDirty = false
        ToastWindow.show(message: "Saved")
    }
}
