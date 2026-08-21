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

    /// Tear down every open note window. Tests only, so one case cannot leak windows into the
    /// next; the app itself closes windows through the normal `windowWillClose` path.
    static func closeAllForTesting() {
        for controller in open.values { controller.window?.close() }
        open.removeAll()
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
///
/// Rendered task lines are the exception: a click on a checkbox toggles it and is swallowed
/// whole, so a checklist behaves like a checkbox list rather than a markdown document that
/// happens to show boxes. That interception happens before edit activation, so it wins even
/// under the single-click-to-edit preference.
final class ModeSwitchingTextView: NSTextView {
    var onActivateEditing: (() -> Void)?
    /// When true, a single click (rather than a double-click) activates editing.
    var activatesOnSingleClick = false

    /// Toggle the task on this source line. Returns true when it was handled.
    var onToggleTask: ((Int) -> Bool)?
    /// In notes that are entirely a checklist, the whole item row toggles, not just the box.
    var togglesWholeTaskLine = false

    private var taskCursorArea: NSTrackingArea?

    /// A rendered task line under the pointer.
    struct TaskHit {
        let sourceLine: Int
        /// True when the point is on the gutter/box run rather than the item's text.
        let isCheckbox: Bool
    }

    /// The task whose click target contains `point` (view coordinates), or nil.
    ///
    /// Only meaningful in read-only mode: edit mode shows raw markdown, which carries no task
    /// attributes. Uses TextKit 1 geometry, which the text view opts into explicitly.
    func taskHit(at point: NSPoint) -> TaskHit? {
        guard !isEditable,
              let layoutManager,
              let textContainer,
              let textStorage, textStorage.length > 0 else { return nil }

        let p = NSPoint(x: point.x - textContainerInset.width,
                        y: point.y - textContainerInset.height)

        // Without this, a click in the empty space below the last line snaps to the final glyph
        // and would silently toggle the last item.
        guard p.y < layoutManager.usedRect(for: textContainer).maxY else { return nil }

        var fraction: CGFloat = 0
        let glyph = layoutManager.glyphIndex(for: p, in: textContainer,
                                             fractionOfDistanceThroughGlyph: &fraction)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        // Vertical containment only. Horizontal snapping is wanted: a click in the left margin
        // maps to the line's first character, which is the checkbox.
        guard p.y >= fragment.minY, p.y < fragment.maxY else { return nil }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyph)
        guard charIndex < textStorage.length else { return nil }

        let attributes = textStorage.attributes(at: charIndex, effectiveRange: nil)
        guard let line = attributes[.tqTaskSourceLine] as? Int else { return nil }
        let isCheckbox = attributes[.tqTaskCheckbox] != nil
        guard isCheckbox || togglesWholeTaskLine else { return nil }
        return TaskHit(sourceLine: line, isCheckbox: isCheckbox)
    }

    /// Typing while read-only activates editing, then the keystroke is applied.
    override func keyDown(with event: NSEvent) {
        if !isEditable, let activate = onActivateEditing {
            activate()
            super.keyDown(with: event) // now editable: the typed character lands
        } else {
            super.keyDown(with: event)
        }
    }

    /// A checkbox click toggles and is swallowed. Otherwise a double-click (or single click,
    /// per preference) while read-only activates editing, and a plain single click selects.
    override func mouseDown(with event: NSEvent) {
        if !isEditable, let hit = taskHit(at: convert(event.locationInWindow, from: nil)) {
            if hit.isCheckbox {
                // Return before both `onActivateEditing` and `super.mouseDown`: that is what
                // stops the single-click-to-edit preference from stealing the click, stops a
                // double-click from toggling and then entering edit mode, and leaves the
                // insertion point and any existing selection untouched.
                if event.clickCount == 1 { _ = onToggleTask?(hit.sourceLine) }
                return
            }
            // Whole-row mode, on the item's text. A single click toggles, but a double-click
            // still falls through to edit activation below: otherwise a note that is entirely
            // checkboxes could never be edited by clicking at all.
            if event.clickCount == 1 {
                // Let AppKit run its drag-select loop first (it returns after mouse-up), then
                // treat a click without a drag as a toggle.
                super.mouseDown(with: event)
                if selectedRange().length == 0 { _ = onToggleTask?(hit.sourceLine) }
                return
            }
        }

        let threshold = activatesOnSingleClick ? 1 : 2
        if !isEditable, event.clickCount >= threshold, let activate = onActivateEditing {
            activate()
        }
        super.mouseDown(with: event)
    }

    // MARK: - Cursor

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let taskCursorArea { removeTrackingArea(taskCursorArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.activeInKeyWindow, .inVisibleRect, .cursorUpdate, .mouseMoved],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        taskCursorArea = area
    }

    override func cursorUpdate(with event: NSEvent) {
        if applyTaskCursor(for: event) { return }
        super.cursorUpdate(with: event)
    }

    /// `cursorUpdate` only fires on area entry, so moving between body text and the gutter
    /// inside the view needs this to keep the cursor honest.
    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        _ = applyTaskCursor(for: event)
    }

    /// Show a pointing hand over a clickable task. Returns true when it applied.
    private func applyTaskCursor(for event: NSEvent) -> Bool {
        guard !isEditable, taskHit(at: convert(event.locationInWindow, from: nil)) != nil else {
            return false
        }
        NSCursor.pointingHand.set()
        return true
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
final class NoteEditorViewController: NSViewController, NSTextViewDelegate, NSTextFieldDelegate, NSMenuItemValidation {
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
    /// Exposed for tests, which drive the editor directly rather than synthesizing events.
    private(set) var textView: ModeSwitchingTextView!
    private var toggleButton: NSButton!
    /// Alternate header trailing constraints: `isHidden` does not deactivate a constraint, and
    /// the toggle button owns the trailing edge, so hiding it would leave a gap.
    private var toggleTrailing: NSLayoutConstraint!
    private var pinTrailing: NSLayoutConstraint!
    private(set) var checklist: ChecklistViewController!
    /// The body the checklist's rows were parsed from, and the last body we wrote. The
    /// staleness guard, mirroring `renderedBody`.
    private var checklistBody: String?
    private var textCommitWork: DispatchWorkItem?
    private var pinButton: ToggleIconButton!

    /// How the body is being presented. A list note is `.checklist`, which is not an editing
    /// mode at all: there is no markdown document to enter or leave.
    enum ContentMode { case checklist, rendered, raw }
    private(set) var contentMode: ContentMode = .rendered
    /// Set by "Edit as Markdown", cleared when the window retargets to another note.
    private(set) var forceMarkdownForSession = false

    private(set) var isEditing = false
    /// The body the current rendered view was built from. Task source-line indices are only
    /// valid for that exact text, so a toggle checks this before writing.
    private var renderedBody: String?
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

        // TextKit 1 on purpose. `MarkdownRenderer` emits `NSTextTable` blocks, which only
        // TextKit 1 lays out, and checkbox hit testing needs `NSLayoutManager` geometry.
        // A bare `NSTextView()` builds a TextKit 2 stack that falls back implicitly; opting
        // in explicitly makes the dependency visible instead of inherited.
        textView = ModeSwitchingTextView(usingTextLayoutManager: false)
        textView.delegate = self
        // Programmatically-created text views default this to false; without it, typing
        // never registers undo actions at all.
        textView.allowsUndo = true
        textView.onActivateEditing = { [weak self] in self?.beginEditingFromView() }
        textView.onToggleTask = { [weak self] line in self?.toggleTask(onSourceLine: line) ?? false }
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

            scrollView.topAnchor.constraint(equalTo: categoryPopup.bottomAnchor, constant: 10),
            scrollView.topAnchor.constraint(greaterThanOrEqualTo: titleField.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        toggleTrailing = toggleButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        pinTrailing = pinButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16)
        toggleTrailing.isActive = true

        // The checklist is a sibling of the text view's scroll view, pinned to the same box.
        // `addChild` also wires the responder chain, so the View menu reaches this controller
        // from a focused item field.
        checklist = ChecklistViewController()
        addChild(checklist)
        checklist.view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(checklist.view)
        NSLayoutConstraint.activate([
            checklist.view.topAnchor.constraint(equalTo: scrollView.topAnchor),
            checklist.view.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            checklist.view.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
            checklist.view.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
        ])
        checklist.view.isHidden = true
        checklist.onCommit = { [weak self] body, reason in
            self?.commitChecklist(body, reason: reason)
        }

        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onEditorFontChanged), name: .editorFontDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidLoad() {
        super.viewDidLoad()
        rebuildCategoryMenu()
        applyMode(desiredMode())
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        // Notes opened in edit mode (new notes, or the always-edit preference) open ready to
        // type; put the cursor at the end of the body. Reads the mode that was actually chosen
        // rather than re-deriving it, since checklists override the always-edit preference.
        if contentMode == .checklist {
            // A brand-new list opens with its one empty item ready to type. Only here, never on
            // a reload, so nothing steals focus later.
            if startInEditMode { checklist.focusFirstEditableRow() }
        } else if isEditing {
            textView.setSelectedRange(NSRange(location: (textView.string as NSString).length, length: 0))
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
        forceMarkdownForSession = false

        let oldKey = note.url.standardizedFileURL
        note = newNote
        titleField.stringValue = newNote.title
        rebuildCategoryMenu()

        // No view lifecycle callbacks fire on a swap, so redo what viewDidLoad does. The
        // per-window `startInEditMode` is deliberately ignored: it applied to the first note.
        applyMode(desiredModeForSwap())
        if isEditing { view.window?.makeFirstResponder(textView) }

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

    // MARK: - Content mode

    /// How this note should be presented right now.
    ///
    /// A list note is a checkbox list, so it outranks `startInEditMode` and ignores the
    /// `noteEditMode` preference entirely: that preference describes how to get from reading
    /// markdown to editing it, a distinction a checklist does not have.
    private func desiredMode() -> ContentMode {
        if forceMarkdownForSession { return .raw }
        let body = NoteStore.shared.body(of: note)
        // Too many rows to lay out as live controls; rendered markdown keeps boxes clickable.
        if body.components(separatedBy: "\n").count > ChecklistViewController.maxRows {
            return .rendered
        }
        if TaskList.isChecklist(body) { return .checklist }
        if startInEditMode { return .raw }
        return PreferencesManager.shared.noteEditMode == .alwaysEdit ? .raw : .rendered
    }

    /// Same as `desiredMode()` but ignoring `startInEditMode`, for a note swap (that flag
    /// applied to the window's first note).
    private func desiredModeForSwap() -> ContentMode {
        if forceMarkdownForSession { return .raw }
        let body = NoteStore.shared.body(of: note)
        if body.components(separatedBy: "\n").count > ChecklistViewController.maxRows {
            return .rendered
        }
        if TaskList.isChecklist(body) { return .checklist }
        return PreferencesManager.shared.noteEditMode == .alwaysEdit ? .raw : .rendered
    }

    private func applyMode(_ mode: ContentMode) {
        contentMode = mode
        let isChecklist = mode == .checklist

        checklist.view.isHidden = !isChecklist
        scrollView.isHidden = isChecklist

        // No pencil on a list note: there is no markdown mode to toggle into.
        toggleButton.isHidden = isChecklist
        toggleTrailing.isActive = !isChecklist
        pinTrailing.isActive = isChecklist

        // Only the checklist holds structured state that can silently diverge from disk.
        NotificationCenter.default.removeObserver(self, name: .notesDidChange, object: nil)
        if isChecklist {
            NotificationCenter.default.addObserver(self, selector: #selector(onNotesChangedExternally),
                                                   name: .notesDidChange, object: nil)
        }

        switch mode {
        case .checklist:
            isEditing = false
            isDirty = false
            let body = NoteStore.shared.body(of: note)
            checklistBody = body
            checklist.load(rows: TaskList.rows(from: body))
        case .rendered:
            renderMarkdown()
        case .raw:
            editRaw()
        }
        updateToggle()
    }

    // MARK: - Checklist persistence

    /// Every checklist write funnels through here. Boxes and structural edits persist
    /// immediately (cheap and rare); text edits debounce so a long typing session is not a
    /// write per keystroke.
    private func commitChecklist(_ body: String, reason: ChecklistViewController.CommitReason) {
        switch reason {
        case .checkbox, .structure, .textCommitted:
            textCommitWork?.cancel()
            writeChecklist(body)
        case .text:
            textCommitWork?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.writeChecklist(body) }
            textCommitWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// Write the checklist body, refusing if the file changed underneath us since we loaded it.
    private func writeChecklist(_ body: String) {
        guard contentMode == .checklist else { return }
        guard body != checklistBody else { return }
        let onDisk = NoteStore.shared.body(of: note)
        guard onDisk == checklistBody else {
            checklistBody = onDisk
            checklist.reload(from: onDisk)
            return
        }
        guard NoteStore.shared.updateBody(of: note, body: body) else {
            ToastWindow.show(message: "Save failed")
            return
        }
        checklistBody = body
    }

    /// Flush a pending checklist edit (debounce or in-progress field) to disk.
    func flushChecklist() {
        guard contentMode == .checklist else { return }
        textCommitWork?.cancel()
        textCommitWork = nil
        checklist.flushPendingEdit()
        writeChecklist(TaskList.body(from: checklist.rows))
    }

    /// An external write landed. Ignore our own; otherwise resync the rows.
    @objc private func onNotesChangedExternally() {
        guard contentMode == .checklist else { return }
        let onDisk = NoteStore.shared.body(of: note)
        guard onDisk != checklistBody else { return }
        guard TaskList.isChecklist(onDisk) else {
            checklistBody = nil
            applyMode(desiredModeForSwap())
            return
        }
        checklistBody = onDisk
        checklist.reload(from: onDisk)
    }

    /// Drop this window into raw markdown for the rest of this note's session, and back.
    /// The deliberate escape hatch for pasting a big list or a note misdetected as a list.
    @objc func toggleChecklistMarkdown(_ sender: Any?) {
        if forceMarkdownForSession {
            saveIfDirty()
            forceMarkdownForSession = false
            applyMode(desiredModeForSwap())
        } else {
            flushChecklist()
            forceMarkdownForSession = true
            applyMode(.raw)
            view.window?.makeFirstResponder(textView)
        }
    }

    /// Render the note's markdown read-only. `preservingViewport` keeps the scroll offset and
    /// selection across the swap, which a checkbox toggle needs (the content is otherwise
    /// identical and jumping to the top on every click would be unusable).
    private func renderMarkdown(preservingViewport: Bool = false) {
        isEditing = false
        isDirty = false
        textView.isEditable = false
        textView.isSelectable = true

        let origin = scrollView.contentView.bounds.origin
        let ranges = textView.selectedRanges

        let body = NoteStore.shared.body(of: note)
        renderedBody = body
        // A note that is entirely tasks is a checkbox list, so the whole row is a target.
        textView.togglesWholeTaskLine = TaskList.isChecklist(body)

        let attributed = MarkdownRenderer.render(body, baseFont: PreferencesManager.shared.editorFont)
        textView.textStorage?.setAttributedString(attributed)
        noteUndoManager.removeAllActions()

        if preservingViewport {
            // setAttributedString invalidates layout, so the document view is momentarily short
            // and an un-forced scroll would clamp to the top.
            if let container = textView.textContainer {
                textView.layoutManager?.ensureLayout(for: container)
            }
            let length = (textView.string as NSString).length
            let clamped = ranges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                guard range.location <= length else { return nil }
                return NSValue(range: NSRange(location: range.location,
                                              length: min(range.length, length - range.location)))
            }
            if !clamped.isEmpty { textView.selectedRanges = clamped }
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }
    }

    // MARK: - Checkboxes

    /// Toggle the checkbox on source line `line` of the current note, write it, and re-render in
    /// place. Returns false when nothing was toggled.
    ///
    /// No "Saved" toast here on purpose: one toast per checkbox click is noise.
    @discardableResult
    func toggleTask(onSourceLine line: Int) -> Bool {
        guard !isEditing else { return false }

        let onDisk = NoteStore.shared.body(of: note)
        // Changed underneath us since we rendered, so the line indices we stamped are stale.
        // Resync rather than write to a guessed line.
        guard onDisk == renderedBody else {
            renderMarkdown()
            return false
        }
        guard let updated = TaskList.toggle(body: onDisk, lineIndex: line) else { return false }
        guard NoteStore.shared.updateBody(of: note, body: updated) else {
            ToastWindow.show(message: "Save failed")
            return false
        }
        renderMarkdown(preservingViewport: true)
        return true
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
        switch contentMode {
        case .checklist:
            // Rows build their fields from the editor font, so rebuild them.
            checklist.load(rows: checklist.rows)
        case .rendered:
            renderMarkdown()
        case .raw:
            break
        }
    }

    // MARK: - Autosave

    func textDidChange(_ notification: Notification) {
        if isEditing { isDirty = true }
    }

    // MARK: - Typing task lines

    /// Turn the caret's line into a task, or flip one that already is (Shift+Cmd+L).
    /// A no-op in view mode, where clicking a checkbox already covers it.
    @objc func toggleTaskMarker(_ sender: Any?) {
        if contentMode == .checklist {
            checklist.toggleFocusedRow()
            return
        }
        guard isEditing else { return }

        let ns = textView.string as NSString
        let selection = textView.selectedRange()
        let lineRange = ns.lineRange(for: NSRange(location: selection.location, length: 0))
        let column = selection.location - lineRange.location

        // Which source line the caret sits on, counting the newlines before it.
        let index = ns.substring(to: lineRange.location).components(separatedBy: "\n").count - 1
        guard let updated = TaskList.toggleOrPromote(body: textView.string, lineIndex: index) else { return }
        guard updated != textView.string else { return }

        let whole = NSRange(location: 0, length: ns.length)
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: whole, replacementString: updated) else { return }
        textView.textStorage?.replaceCharacters(in: whole, with: updated)
        textView.didChangeText()

        // Keep the caret at the same column, shifted by however much the prefix grew or shrank.
        let newLength = (updated as NSString).length
        let delta = newLength - ns.length
        let restored = min(max(lineRange.location + column + delta, 0), newLength)
        textView.setSelectedRange(NSRange(location: restored, length: 0))
    }

    /// Enable the Edit menu's Toggle Task item only while editing raw markdown.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == Selector(("toggleChecklistMarkdown:")) {
            menuItem.title = forceMarkdownForSession ? "Edit as Checklist" : "Edit as Markdown"
            return contentMode == .checklist || forceMarkdownForSession
        }
        if menuItem.action == Selector(("toggleTaskMarker:")) {
            return isEditing || contentMode == .checklist
        }
        return true
    }

    /// Intercept Return so typing a checklist continues it. Everything else falls through.
    func textView(_ view: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)), isEditing else {
            return false
        }
        return continueTaskList()
    }

    /// Handle Return on a task line: continue the list, or clear an empty item to end it.
    /// Returns false to let AppKit insert a plain newline.
    func continueTaskList() -> Bool {
        let selection = textView.selectedRange()
        // Return over a selection is a plain replace, not a list continuation.
        guard selection.length == 0 else { return false }

        let ns = textView.string as NSString
        let lineRange = ns.lineRange(for: selection)
        // The line without its terminator, plus the range that content occupies.
        var contentLength = lineRange.length
        while contentLength > 0 {
            let character = ns.character(at: lineRange.location + contentLength - 1)
            guard character == 0x0A || character == 0x0D else { break }
            contentLength -= 1
        }
        let contentRange = NSRange(location: lineRange.location, length: contentLength)
        let line = ns.substring(with: contentRange)

        // Only continue from the end of the line; Return mid-item just splits it.
        guard selection.location >= NSMaxRange(contentRange) else { return false }

        let target: NSRange
        let replacement: String
        switch TaskList.returnAction(for: line) {
        case .pass:
            return false
        case .continueList(let prefix):
            target = NSRange(location: selection.location, length: 0)
            replacement = "\n" + prefix
        case .clearMarker:
            // Wipe the empty item in place rather than adding another one below it.
            target = contentRange
            replacement = ""
        }

        // breakUndoCoalescing is load-bearing: without it the inserted item merges into the
        // preceding typing group, and one Cmd+Z would rip out the whole item plus its text.
        textView.breakUndoCoalescing()
        guard textView.shouldChangeText(in: target, replacementString: replacement) else {
            return true
        }
        textView.textStorage?.replaceCharacters(in: target, with: replacement)
        textView.didChangeText()
        textView.setSelectedRange(NSRange(location: target.location + (replacement as NSString).length,
                                          length: 0))
        return true
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
        flushChecklist()
        guard isEditing, isDirty else { return }
        _ = NoteStore.shared.updateBody(of: note, body: textView.string)
        isDirty = false
        ToastWindow.show(message: "Saved")
    }
}
