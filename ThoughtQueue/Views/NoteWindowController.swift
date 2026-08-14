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
final class NoteWindowController: NSWindowController, NSWindowDelegate, NSMenuItemValidation {
    /// Live windows keyed by standardized note URL, so we reuse rather than duplicate.
    private static var open: [URL: NoteWindowController] = [:]

    private var noteURL: URL
    private let editor: NoteEditorViewController

    /// The window's content is a split view: the collapsible navigator on the left, the editor
    /// on the right.
    private let splitVC = NSSplitViewController()
    private let navigator = NoteNavigatorViewController()
    private var navigatorItem: NSSplitViewItem!
    /// Mirrors `navigatorItem.isCollapsed` (inverted) for the header button. Kept in sync by KVO
    /// because sidebar-behavior items also auto-collapse when the window gets narrow.
    private var navigatorVisible = false
    private var collapseObservation: NSKeyValueObservation?

    /// Whether the navigation panel is currently showing. Read by tests.
    var isNavigatorVisible: Bool { navigatorVisible }

    /// Thickness limits for the navigator, mirrored by `PreferencesManager.noteNavigatorWidth`.
    private static let navigatorMinWidth: CGFloat = 160
    private static let navigatorMaxWidth: CGFloat = 320

    /// Whether this window is currently floating above other windows. Seeded from the
    /// `noteAlwaysOnTop` preference when the window opens, but then owned per-window: the
    /// header's pin button flips it for this session only, and closing/reopening the note
    /// starts fresh from the preference again.
    private var sessionAlwaysOnTop: Bool

    /// Open (or focus) a window for an existing note, starting in view mode.
    static func show(note: Note) {
        let key = note.url.standardizedFileURL
        if let existing = open[key] {
            focus(existing.window)
            return
        }
        present(note: note, startInEditMode: false)
    }

    /// Bring an already-open note window to the front of the Space the user is on.
    ///
    /// `makeKeyAndOrderFront` alone leaves a window on another desktop where it is, so
    /// re-selecting that note from the popover or navigator feels like a no-op. Adding
    /// `.moveToActiveSpace` pulls the window onto the current Space; deminiaturizing
    /// covers the Dock-minimized case. Activate the app before ordering front so
    /// LSUIElement / accessory policy still receives key status.
    static func focus(_ window: NSWindow?) {
        guard let window else { return }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.collectionBehavior.insert(.moveToActiveSpace)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
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
        focus(wc.window)
    }

    private init(note: Note, startInEditMode: Bool) {
        self.noteURL = note.url.standardizedFileURL
        self.editor = NoteEditorViewController(note: note, startInEditMode: startInEditMode)
        self.sessionAlwaysOnTop = PreferencesManager.shared.noteAlwaysOnTop

        let size = PreferencesManager.shared.noteWindowSize
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: size.width, height: size.height),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = note.title

        // The navigator lives in a collapsible sidebar item left of the editor. It starts
        // collapsed via the plain setter (the animator misbehaves before the view is in a
        // window), and the split view deliberately has no autosaveName: that restores collapse
        // state asynchronously, which would defeat "hidden by default", and every note window
        // would share the one key. Spring loading is off so a drag near the edge can't reveal
        // it either — the header button and ⌃⌘S are the only ways in.
        let navigatorItem = NSSplitViewItem(sidebarWithViewController: navigator)
        navigatorItem.canCollapse = true
        navigatorItem.minimumThickness = Self.navigatorMinWidth
        navigatorItem.maximumThickness = Self.navigatorMaxWidth
        navigatorItem.holdingPriority = NSLayoutConstraint.Priority(260) // resists resize, keeps its width
        navigatorItem.isSpringLoaded = false
        self.navigatorItem = navigatorItem

        let editorItem = NSSplitViewItem(viewController: editor)
        editorItem.minimumThickness = 240 // 160 + 240 < the 460 default width, so both fit
        editorItem.holdingPriority = NSLayoutConstraint.Priority(250) // lowest absorbs window resizes

        splitVC.addSplitViewItem(navigatorItem)
        splitVC.addSplitViewItem(editorItem)
        window.contentViewController = splitVC
        // Assigning contentViewController resizes the window to the content view's fixed
        // loadView size, clobbering the contentRect above. Re-apply the remembered size
        // afterward so restored sizes actually stick.
        window.setContentSize(size)

        // Collapse only after the split view is installed, then force the layout pass right
        // away. Collapsing beforehand leaves the divider geometry uncommitted until something
        // else triggers the first layout — moving the mouse toward the left edge updates the
        // divider's tracking areas and does exactly that, which flashed the (still empty)
        // navigator open for a moment the first time a note window was used.
        navigatorItem.isCollapsed = true
        splitVC.view.layoutSubtreeIfNeeded()
        window.center()
        super.init(window: window)
        window.delegate = self
        applyAlwaysOnTop()

        // Let the header's pin button flip this window's float state for the session only.
        editor.isPinned = sessionAlwaysOnTop
        editor.onTogglePin = { [weak self] in
            guard let self else { return }
            self.sessionAlwaysOnTop.toggle()
            self.applyAlwaysOnTop()
            self.editor.isPinned = self.sessionAlwaysOnTop
        }

        // Update this window's level live when the "keep notes on top" preference toggles.
        NotificationCenter.default.addObserver(
            self, selector: #selector(preferenceDidChange), name: .noteAlwaysOnTopDidChange, object: nil)

        // Keep the registry key and window title in sync when the note is renamed, moved, or
        // swapped out for another note from the navigator.
        editor.onNoteChanged = { [weak self] newNote, oldKey in
            guard let self else { return }
            let newKey = newNote.url.standardizedFileURL
            if NoteWindowController.open[oldKey] === self {
                NoteWindowController.open[oldKey] = nil
            }
            self.noteURL = newKey
            NoteWindowController.open[newKey] = self
            self.window?.title = newNote.title
            self.navigator.highlight(note: newNote)
        }

        // Picking a note in the navigator switches this window over to it.
        navigator.onNoteSelected = { [weak self] selected in
            self?.retarget(to: selected)
        }
        editor.onToggleNavigator = { [weak self] in
            guard let self else { return }
            self.setNavigator(visible: self.navigatorItem.isCollapsed)
        }

        // AppKit auto-collapses sidebar items when the window gets narrow, so the header button
        // would otherwise claim the panel is open when it isn't.
        collapseObservation = navigatorItem.observe(\.isCollapsed, options: [.new]) { [weak self] item, _ in
            guard let self else { return }
            self.navigatorVisible = !item.isCollapsed
            self.editor.isNavigatorVisible = self.navigatorVisible
        }

        // Remember a dragged divider position. Observing the split view avoids taking over
        // NSSplitViewController's own delegate.
        NotificationCenter.default.addObserver(
            self, selector: #selector(splitViewDidResize),
            name: NSSplitView.didResizeSubviewsNotification, object: splitVC.splitView)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The level used when a note window is pinned. Deliberately one step above `.normal`
    /// rather than `.floating`: spell checkers and similar annotation tools draw their
    /// overlays at `.floating` (Quillbot does), and matching their level leaves the stacking
    /// order to be broken by focus, which hides their underlines behind a pinned note. One
    /// still floats above every ordinary app window.
    static let pinnedLevel = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)

    /// Float the window above other windows, or drop it back to normal, per this window's
    /// session state.
    private func applyAlwaysOnTop() {
        window?.level = sessionAlwaysOnTop ? Self.pinnedLevel : .normal
    }

    /// Re-sync to the global preference when it changes (e.g. from Preferences), so toggling
    /// the setting still lifts/drops already-open windows. This resets any per-session pin
    /// override to follow the new preference value.
    @objc private func preferenceDidChange() {
        sessionAlwaysOnTop = PreferencesManager.shared.noteAlwaysOnTop
        applyAlwaysOnTop()
        editor.isPinned = sessionAlwaysOnTop
    }

    // MARK: - Navigation panel

    /// Toggle the navigation panel. Wired to the View menu (⌃⌘S) via nil-target dispatch, which
    /// reaches this window controller through the responder chain.
    @objc func toggleNoteNavigator(_ sender: Any?) {
        setNavigator(visible: navigatorItem.isCollapsed)
    }

    /// Reveal or hide the navigator. The window keeps its size, so the editor is squeezed;
    /// dragging the divider back is remembered for next time.
    private func setNavigator(visible: Bool) {
        guard navigatorItem.isCollapsed == visible else { return }
        navigatorVisible = visible
        editor.isNavigatorVisible = visible
        if visible {
            navigator.reload()
            navigator.highlight(note: editor.currentNote)
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            navigatorItem.animator().isCollapsed = !visible
        }
    }

    /// Show `note` in this window instead of the current one, keeping the one-window-per-note
    /// invariant: a note that already has its own window is fronted rather than stolen.
    private func retarget(to note: Note) {
        let key = note.url.standardizedFileURL
        guard key != noteURL else {
            // Already showing this note — still focus this window (minimized / buried).
            Self.focus(window)
            return
        }

        guard FileManager.default.fileExists(atPath: note.url.path) else {
            ToastWindow.show(message: "Note no longer exists")
            navigator.reload()
            navigator.highlight(note: editor.currentNote)
            return
        }

        if let existing = NoteWindowController.open[key], existing !== self {
            // Restore this window's navigator selection before focusing the other window;
            // outline selection otherwise orders this window front again and undoes the focus.
            navigator.highlight(note: editor.currentNote)
            Self.focus(existing.window)
            return
        }

        editor.load(note: note) // re-keys the registry and retitles via onNoteChanged
    }

    /// Persist the navigator's width whenever the user drags the divider.
    @objc private func splitViewDidResize() {
        guard let navigatorItem, !navigatorItem.isCollapsed else { return }
        let width = navigator.view.frame.width
        guard width > 0 else { return }
        PreferencesManager.shared.noteNavigatorWidth = width
    }

    /// Keep the View menu item's title in step with the panel's state.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleNoteNavigator(_:)) {
            menuItem.title = navigatorVisible ? "Hide Notes Panel" : "Show Notes Panel"
        }
        return true
    }

    /// Remember the new size so every subsequently opened note window matches it. Uses the
    /// content view's size (not the frame) so the title bar isn't counted, keeping it
    /// consistent with the `contentRect` the window is created with.
    func windowDidResize(_ notification: Notification) {
        guard let contentSize = window?.contentView?.frame.size else { return }
        PreferencesManager.shared.noteWindowSize = contentSize
    }

    /// Persist any pending edit and drop our registry entry when the window closes.
    func windowWillClose(_ notification: Notification) {
        editor.saveIfDirty()
        NotificationCenter.default.removeObserver(self, name: .noteAlwaysOnTopDidChange, object: nil)
        NotificationCenter.default.removeObserver(
            self, name: NSSplitView.didResizeSubviewsNotification, object: splitVC.splitView)
        collapseObservation?.invalidate()
        collapseObservation = nil
        // Last, since dropping the registry entry can release the final reference to self.
        NoteWindowController.open[noteURL] = nil
    }

    /// Route the window's undo/redo (Edit menu, Cmd+Z/Cmd+Shift+Z) to the editor's own
    /// undo manager instead of AppKit's lazily-created default, so we can reset it
    /// ourselves when the buffer is reloaded outside of user typing (see `noteUndoManager`).
    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? {
        editor.noteUndoManager
    }
}

extension NSWindow {
    /// The note editor this window hosts, whether it is the content view controller itself or a
    /// child of the note window's split view. Keeps callers independent of the container.
    var noteEditor: NoteEditorViewController? {
        if let editor = contentViewController as? NoteEditorViewController { return editor }
        return contentViewController?.children.compactMap { $0 as? NoteEditorViewController }.first
    }
}

/// An NSTextView that, while in read-only (rendered markdown) view mode, switches into edit
/// mode when the user tries to type, paste, or double-click, instead of doing nothing. A
/// single click still just selects/positions, so text stays readable and selectable.
final class ModeSwitchingTextView: NSTextView {
    var onActivateEditing: (() -> Void)?
    /// When true, a single click (rather than a double-click) activates editing.
    var activatesOnSingleClick = false

    /// Typing while read-only activates editing, then the keystroke is applied.
    override func keyDown(with event: NSEvent) {
        if !isEditable, let activate = onActivateEditing {
            activate()
            super.keyDown(with: event) // now editable: the typed character lands
        } else {
            super.keyDown(with: event)
        }
    }

    /// A double-click (or single click, per preference) while read-only activates editing;
    /// otherwise a single click is left to select.
    override func mouseDown(with event: NSEvent) {
        let threshold = activatesOnSingleClick ? 1 : 2
        if !isEditable, event.clickCount >= threshold, let activate = onActivateEditing {
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

/// An icon button with an on/off fill (used for the header's pin toggle): a soft accent wash
/// when active, transparent otherwise. `wantsUpdateLayer`/`updateLayer()` (see
/// `ThemedSurfaceView`) keeps that fill correct across light/dark appearance changes instead of
/// a one-off `cgColor` write going stale.
final class ToggleIconButton: NSButton {
    var isActive = false { didSet { needsDisplay = true } }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = isActive ? Theme.accentSoftBackground.cgColor : NSColor.clear.cgColor
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

    /// Called when the header's pin (keep-on-top) button is clicked. The owning window flips
    /// its float state and reports the result back via `isPinned`.
    var onTogglePin: (() -> Void)?

    /// Reflects whether the owning window is currently floating; drives the pin button's
    /// icon. Set by the owning window, not by this controller.
    var isPinned = false { didSet { updatePinButton() } }

    /// Called when the header's navigation-panel button is clicked. The owning window reveals or
    /// hides the panel and reports the result back via `isNavigatorVisible`.
    var onToggleNavigator: (() -> Void)?

    /// Reflects whether the owning window's navigation panel is showing; drives that button's
    /// state. Set by the owning window, not by this controller.
    var isNavigatorVisible = false { didSet { updateNavigatorButton() } }

    private var titleField: NSTextField!
    private var navigatorButton: NSButton!
    private var categoryPopup: NSPopUpButton!
    private var scrollView: NSScrollView!
    private var textView: ModeSwitchingTextView!
    private var toggleButton: NSButton!
    private var pinButton: ToggleIconButton!

    private var isEditing = false
    /// True when the raw text has unsaved changes since the last save/load.
    private var isDirty = false
    /// Backs the window's undo/redo (see `NoteWindowController.windowWillReturnUndoManager`).
    /// Typing is registered automatically by the text system; we reset this manager
    /// ourselves whenever the buffer is replaced programmatically (mode toggle, initial
    /// load) since those swaps bypass undo registration and would otherwise leave stale
    /// actions pointing at text ranges that no longer exist.
    let noteUndoManager = UndoManager()
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
        let container = ThemedSurfaceView(frame: NSRect(x: 0, y: 0, width: 460, height: 520))

        // Reveals/hides the window's navigation panel. Leading edge of the header, where macOS
        // sidebar toggles live.
        navigatorButton = NSButton(title: "", target: self, action: #selector(toggleNavigator))
        navigatorButton.bezelStyle = .rounded
        navigatorButton.setButtonType(.pushOnPushOff)
        navigatorButton.imagePosition = .imageOnly
        navigatorButton.contentTintColor = Theme.iconStroke
        navigatorButton.setContentHuggingPriority(.required, for: .horizontal)
        navigatorButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(navigatorButton)
        updateNavigatorButton()

        // Monospaced to read as "this is the filename", matching the design.
        titleField = NSTextField(string: note.title)
        titleField.font = .monospacedSystemFont(ofSize: 15, weight: .bold)
        titleField.textColor = Theme.textPrimary
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

        // Per-session "keep on top" toggle. Defaults to the preference each time a note
        // opens; clicking flips only this window's float state.
        pinButton = ToggleIconButton(title: "", target: self, action: #selector(togglePin))
        pinButton.bezelStyle = .rounded
        pinButton.imagePosition = .imageOnly
        pinButton.wantsLayer = true
        pinButton.layer?.cornerRadius = Theme.radiusSmall
        pinButton.setContentHuggingPriority(.required, for: .horizontal)
        pinButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pinButton)
        updatePinButton()

        toggleButton = NSButton(title: "", target: self, action: #selector(toggleMode))
        toggleButton.bezelStyle = .rounded
        toggleButton.imagePosition = .imageOnly
        toggleButton.contentTintColor = Theme.iconStroke
        toggleButton.setContentHuggingPriority(.required, for: .horizontal)
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(toggleButton)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = Theme.surface
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView = ModeSwitchingTextView()
        textView.delegate = self
        // Programmatically-created text views default this to false; without it, typing
        // never registers undo actions at all.
        textView.allowsUndo = true
        textView.onActivateEditing = { [weak self] in self?.beginEditingFromView() }
        textView.activatesOnSingleClick = PreferencesManager.shared.noteEditMode == .singleClick
        textView.font = PreferencesManager.shared.editorFont
        textView.isRichText = false
        // Keep pasted/typed text verbatim: no curly quotes, em dashes, or text
        // replacements that break when the note is later pasted into a terminal.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.smartInsertDeleteEnabled = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.drawsBackground = true
        textView.backgroundColor = Theme.surface
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            navigatorButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            navigatorButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),

            titleField.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            titleField.leadingAnchor.constraint(equalTo: navigatorButton.trailingAnchor, constant: 8),

            categoryPopup.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            categoryPopup.leadingAnchor.constraint(equalTo: titleField.trailingAnchor, constant: 8),

            pinButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            pinButton.leadingAnchor.constraint(equalTo: categoryPopup.trailingAnchor, constant: 8),

            toggleButton.centerYAnchor.constraint(equalTo: titleField.centerYAnchor),
            toggleButton.leadingAnchor.constraint(equalTo: pinButton.trailingAnchor, constant: 8),
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
        if startInEditMode || PreferencesManager.shared.noteEditMode == .alwaysEdit {
            editRaw()
        } else {
            renderMarkdown() // default to view mode
        }
        updateToggle()
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Notes opened in edit mode (new notes, or the always-edit preference) open ready to
        // type; put the cursor in the body.
        if startInEditMode || PreferencesManager.shared.noteEditMode == .alwaysEdit {
            view.window?.makeFirstResponder(textView)
        }
    }

    // MARK: - Switching notes

    /// The note currently on screen. Read by the owning window when it retargets.
    var currentNote: Note { note }

    /// Show a different note in this same editor. Pending title and body edits are flushed
    /// first, in that order (a title edit renames the file, so it has to land before the old URL
    /// is captured), then the swap is reported through `onNoteChanged` so the window re-keys its
    /// registry entry and retitles.
    func load(note newNote: Note) {
        _ = view
        guard newNote.url.standardizedFileURL != note.url.standardizedFileURL else { return }
        commitTitleIfNeeded()
        saveIfDirty()

        let oldKey = note.url.standardizedFileURL
        note = newNote
        titleField.stringValue = newNote.title
        rebuildCategoryMenu()

        // No view lifecycle callbacks fire on a swap, so redo what viewDidLoad does. The
        // per-window `startInEditMode` is deliberately ignored: it applied to the first note.
        if PreferencesManager.shared.noteEditMode == .alwaysEdit {
            editRaw()
            view.window?.makeFirstResponder(textView)
        } else {
            renderMarkdown()
        }
        updateToggle()

        // Start the new note at the top rather than inheriting the old note's scroll offset.
        textView.setSelectedRange(NSRange(location: 0, length: 0))
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)

        onNoteChanged?(newNote, oldKey)
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

    /// Forward a pin-button click to the owning window, which flips the float state.
    @objc private func togglePin() {
        onTogglePin?()
    }

    /// Forward a navigation-panel button click to the owning window, which reveals/hides it.
    @objc private func toggleNavigator() {
        onToggleNavigator?()
    }

    /// Reflect the panel's state in the navigator button. The icon is the same either way (as in
    /// Apple's apps); the pressed state and tooltip carry the difference.
    private func updateNavigatorButton() {
        guard let navigatorButton else { return }
        let tip = isNavigatorVisible ? "Hide Notes Panel" : "Show Notes Panel"
        navigatorButton.image = NSImage(systemSymbolName: "sidebar.leading", accessibilityDescription: tip)
        navigatorButton.toolTip = tip
        navigatorButton.state = isNavigatorVisible ? .on : .off
    }

    /// Reflect the current pinned state in the pin button's icon, tooltip, and fill: a soft
    /// sage wash when pinned, matching the design's active-toggle treatment.
    private func updatePinButton() {
        guard let pinButton else { return }
        let symbol = isPinned ? "pin.fill" : "pin"
        let tip = isPinned ? "Stop keeping on top" : "Keep on top"
        pinButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        pinButton.toolTip = tip
        pinButton.contentTintColor = isPinned ? Theme.accentBorder : Theme.iconStroke
        pinButton.isActive = isPinned
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
        noteUndoManager.removeAllActions()
    }

    private func editRaw() {
        isEditing = true
        isDirty = false
        textView.isEditable = true
        // Pin the editor font and color: setting `string` inherits the attributes of the
        // rendered text's first character, which may be a larger heading font or (when the
        // note starts with a blank line) no attributes at all. Text with no foreground
        // color draws black regardless of appearance, so reapply both explicitly.
        let font = PreferencesManager.shared.editorFont
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.string = NoteStore.shared.body(of: note)
        textView.font = font
        textView.textColor = .labelColor
        noteUndoManager.removeAllActions()
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
