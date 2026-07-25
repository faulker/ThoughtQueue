import XCTest
@testable import ThoughtQueue

/// Verifies the per-note window behavior: opening the same note twice reuses one window,
/// and the window opens in read-only (view) mode by default.
@MainActor
final class NoteWindowControllerTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!
    private var savedEditMode: NoteEditMode!
    private var savedAlwaysOnTop: Bool!
    private var savedWindowSize: NSSize!
    private var savedNavigatorWidth: CGFloat!

    override func setUpWithError() throws {
        closeNoteWindows() // isolate from any windows a prior case left behind
        savedEditMode = PreferencesManager.shared.noteEditMode
        savedAlwaysOnTop = PreferencesManager.shared.noteAlwaysOnTop
        savedWindowSize = PreferencesManager.shared.noteWindowSize
        savedNavigatorWidth = PreferencesManager.shared.noteNavigatorWidth
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-win-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        closeNoteWindows()
        PreferencesManager.shared.noteEditMode = savedEditMode
        PreferencesManager.shared.noteAlwaysOnTop = savedAlwaysOnTop
        PreferencesManager.shared.noteWindowSize = savedWindowSize
        PreferencesManager.shared.noteNavigatorWidth = savedNavigatorWidth
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    /// Close every note window and drain the run loop so they leave `NSApp.windows`.
    private func closeNoteWindows() {
        noteWindows().forEach { $0.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func noteWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.noteEditor != nil }
    }

    /// The note window for a specific note (matched by its title), so leftover windows
    /// from other cases don't interfere.
    private func window(for note: Note) throws -> NSWindow {
        try XCTUnwrap(noteWindows().first { $0.title == note.title })
    }

    func testOpeningSameNoteTwiceReusesWindow() throws {
        let note = try XCTUnwrap(store.createNote(title: "Reuse Me", body: "hello", category: nil))
        let before = noteWindows().count

        NoteWindowController.show(note: note)
        NoteWindowController.show(note: note)

        XCTAssertEqual(noteWindows().count, before + 1, "same note should reuse a single window")
    }

    func testWindowOpensInViewMode() throws {
        let note = try XCTUnwrap(store.createNote(title: "Viewable", body: "# Heading", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let scrollView = try XCTUnwrap(firstView(NSScrollView.self, in: editor.view))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertFalse(textView.isEditable, "notes should open read-only in view mode by default")
    }

    func testEditorDisablesAutomaticTextSubstitutions() throws {
        let note = try XCTUnwrap(store.createNote(title: "Verbatim", body: "code", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let scrollView = try XCTUnwrap(firstView(NSScrollView.self, in: editor.view))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)

        XCTAssertFalse(textView.isAutomaticQuoteSubstitutionEnabled, "smart quotes must stay off so quotes survive a terminal paste")
        XCTAssertFalse(textView.isAutomaticDashSubstitutionEnabled, "smart dashes must stay off")
        XCTAssertFalse(textView.isAutomaticTextReplacementEnabled, "text replacement must stay off")
    }

    func testAlwaysEditModeOpensExistingNoteEditable() throws {
        PreferencesManager.shared.noteEditMode = .alwaysEdit
        let note = try XCTUnwrap(store.createNote(title: "Always Edit", body: "# Heading", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let scrollView = try XCTUnwrap(firstView(NSScrollView.self, in: editor.view))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertTrue(textView.isEditable, "always-edit mode should open existing notes editable")
    }

    func testWindowFloatsWhenAlwaysOnTopEnabled() throws {
        PreferencesManager.shared.noteAlwaysOnTop = true
        let note = try XCTUnwrap(store.createNote(title: "Floater", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        XCTAssertEqual(window.level, NoteWindowController.pinnedLevel, "note window should float when the preference is on")
    }

    /// Spell checkers and similar annotation tools draw their overlays at `.floating`. A
    /// pinned note must stay strictly below that (but still above `.normal`), otherwise the
    /// stacking order falls back to focus order and the note covers their underlines.
    func testPinnedLevelSitsBetweenNormalAndFloating() {
        XCTAssertGreaterThan(NoteWindowController.pinnedLevel.rawValue, NSWindow.Level.normal.rawValue,
                             "a pinned note must still float above ordinary windows")
        XCTAssertLessThan(NoteWindowController.pinnedLevel.rawValue, NSWindow.Level.floating.rawValue,
                          "a pinned note must stay below spell checker overlays, which use .floating")
    }

    func testWindowStaysNormalWhenAlwaysOnTopDisabled() throws {
        PreferencesManager.shared.noteAlwaysOnTop = false
        let note = try XCTUnwrap(store.createNote(title: "Grounded", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        XCTAssertEqual(window.level, .normal, "note window should sit at normal level when the preference is off")
    }

    func testOpenWindowUpdatesLevelWhenPreferenceToggles() throws {
        PreferencesManager.shared.noteAlwaysOnTop = false
        let note = try XCTUnwrap(store.createNote(title: "Live Toggle", body: "x", category: nil))
        NoteWindowController.show(note: note)
        let window = try window(for: note)
        XCTAssertEqual(window.level, .normal)

        // Flipping the preference should push already-open windows to float, and back.
        PreferencesManager.shared.noteAlwaysOnTop = true
        XCTAssertEqual(window.level, NoteWindowController.pinnedLevel, "toggling the preference should lift open windows")
        PreferencesManager.shared.noteAlwaysOnTop = false
        XCTAssertEqual(window.level, .normal, "toggling back should drop open windows to normal")
    }

    /// The header's pin button starts from the preference, and clicking it flips only this
    /// window's float state (without touching the global preference).
    func testPinButtonTogglesSessionFloatState() throws {
        PreferencesManager.shared.noteAlwaysOnTop = false
        let note = try XCTUnwrap(store.createNote(title: "Pinnable", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let pinButton = try XCTUnwrap(pinButton(in: editor.view))

        XCTAssertEqual(window.level, .normal, "should start from the (off) preference")

        pinButton.performClick(nil)
        XCTAssertEqual(window.level, NoteWindowController.pinnedLevel, "clicking pin should lift this window")
        XCTAssertFalse(PreferencesManager.shared.noteAlwaysOnTop, "the pin button must not change the global preference")

        pinButton.performClick(nil)
        XCTAssertEqual(window.level, .normal, "clicking pin again should drop it back")
    }

    /// Closing and reopening a note discards its per-session pin override and starts fresh
    /// from the preference again.
    func testReopeningNoteResetsPinToPreference() throws {
        PreferencesManager.shared.noteAlwaysOnTop = false
        let note = try XCTUnwrap(store.createNote(title: "Reset Pin", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let firstWindow = try window(for: note)
        let firstEditor = try XCTUnwrap(firstWindow.noteEditor)
        try XCTUnwrap(pinButton(in: firstEditor.view)).performClick(nil)
        XCTAssertEqual(firstWindow.level, NoteWindowController.pinnedLevel, "the session pin should float the window")

        closeNoteWindows()
        // Drain (bounded) until the closed window has left NSApp.windows, so the title match
        // below can't pick up the stale (floating) window instead of the fresh one.
        for _ in 0..<20 where noteWindows().contains(where: { $0 === firstWindow }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        NoteWindowController.show(note: note)

        let reopened = try XCTUnwrap(noteWindows().first { $0 !== firstWindow })
        XCTAssertEqual(reopened.level, .normal, "reopening should default back to the (off) preference")
    }

    func testEditModeControlsSingleClickThreshold() throws {
        PreferencesManager.shared.noteEditMode = .singleClick
        let single = try XCTUnwrap(store.createNote(title: "Single", body: "x", category: nil))
        NoteWindowController.show(note: single)
        let singleView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: try window(for: single).noteEditor!.view))
        XCTAssertTrue(singleView.activatesOnSingleClick, "single-click mode should activate editing on one click")

        PreferencesManager.shared.noteEditMode = .doubleClick
        let double = try XCTUnwrap(store.createNote(title: "Double", body: "x", category: nil))
        NoteWindowController.show(note: double)
        let doubleView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: try window(for: double).noteEditor!.view))
        XCTAssertFalse(doubleView.activatesOnSingleClick, "double-click mode should require a double-click")
    }

    func testTitleFieldShowsNoteTitleAndIsEditable() throws {
        let note = try XCTUnwrap(store.createNote(title: "Editable Title", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let titleField = try XCTUnwrap(firstTitleField(in: editor.view))
        XCTAssertEqual(titleField.stringValue, note.title)
        XCTAssertTrue(titleField.isEditable)
    }

    func testCategoryPopupReflectsAndListsCategories() throws {
        _ = try XCTUnwrap(store.createNote(title: "Other", body: "x", category: "Personal"))
        let note = try XCTUnwrap(store.createNote(title: "Work Note", body: "x", category: "Work"))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let popup = try XCTUnwrap(firstView(NSPopUpButton.self, in: editor.view))

        XCTAssertEqual(popup.titleOfSelectedItem, "Work", "popup should preselect the note's category")
        let titles = popup.itemTitles
        XCTAssertTrue(titles.contains("Work"))
        XCTAssertTrue(titles.contains("Personal"))
        XCTAssertTrue(titles.contains(Note.uncategorized))
    }

    func testShowNewCreatesNoteAndOpensInEditMode() throws {
        let before = store.allNotes().count
        let note = try XCTUnwrap(NoteWindowController.showNew(body: "fresh body"))

        XCTAssertEqual(store.allNotes().count, before + 1, "showNew should create a note on disk")

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let scrollView = try XCTUnwrap(firstView(NSScrollView.self, in: editor.view))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertTrue(textView.isEditable, "new notes should open straight in edit mode")
        XCTAssertEqual(textView.string, "fresh body", "the editor should be pre-filled with the body")
    }

    /// Fix #1: typing a new title and then switching category must not revert the title.
    func testChangingCategoryPreservesUncommittedTitleEdit() throws {
        _ = store.createCategory("Work")
        let note = try XCTUnwrap(store.createNote(title: "Original", body: "body", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        let titleField = try XCTUnwrap(firstTitleField(in: editor.view))
        let popup = try XCTUnwrap(firstView(NSPopUpButton.self, in: editor.view))

        // Simulate typing a new title WITHOUT committing it, then switching category.
        // Titles are stored as slugified filenames, so "Renamed Title" becomes "renamed-title".
        titleField.stringValue = "Renamed Title"
        popup.selectItem(withTitle: "Work")
        popup.target?.perform(popup.action, with: popup)

        let notes = store.allNotes()
        XCTAssertTrue(notes.contains { $0.title == "renamed-title" && $0.category == "Work" },
                      "the typed title should survive a category change")
        XCTAssertFalse(notes.contains { $0.title == "original" },
                       "the note should no longer carry its old title")
        XCTAssertEqual(titleField.stringValue, "renamed-title")
    }

    /// Typing (simulated via `insertText`, which goes through the same undo-registering
    /// path as a real keystroke) should be undoable and redoable via the window's undo
    /// manager, which the window delegate routes to the editor's own manager.
    func testTypingIsUndoableAndRedoable() throws {
        let note = try XCTUnwrap(store.createNote(title: "Undo Me", body: "start", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        // View mode by default; switch into edit mode like the toggle button would.
        editor.perform(Selector(("toggleMode")))
        let textView = try XCTUnwrap(firstView(NSTextView.self, in: editor.view))

        XCTAssertTrue(window.undoManager === editor.noteUndoManager, "window should route undo to the editor's manager")

        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.insertText(" more", replacementRange: textView.selectedRange())
        XCTAssertEqual(textView.string, "start more")

        window.undoManager?.undo()
        XCTAssertEqual(textView.string, "start", "undo should revert the typed text")

        window.undoManager?.redo()
        XCTAssertEqual(textView.string, "start more", "redo should reapply the typed text")
    }

    /// Switching modes reloads the buffer from disk outside of the undo-registering text
    /// path; any undo history from a prior edit session must not survive the reload, since
    /// it would otherwise point at text ranges that no longer exist.
    func testUndoHistoryClearsOnModeToggle() throws {
        let note = try XCTUnwrap(store.createNote(title: "Reset Undo", body: "start", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.noteEditor)
        editor.perform(Selector(("toggleMode"))) // into edit mode
        let textView = try XCTUnwrap(firstView(NSTextView.self, in: editor.view))

        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.insertText(" more", replacementRange: textView.selectedRange())
        XCTAssertTrue(editor.noteUndoManager.canUndo)

        editor.perform(Selector(("toggleMode"))) // back to view mode (saves + reloads)
        XCTAssertFalse(editor.noteUndoManager.canUndo, "leaving edit mode should clear stale undo history")
    }

    /// A note window should open at the remembered size, not the editor view's fixed
    /// loadView size. Regression: assigning contentViewController resizes the window to the
    /// view's size, which was clobbering the restored size.
    func testWindowOpensAtRememberedSize() throws {
        PreferencesManager.shared.noteWindowSize = NSSize(width: 720, height: 640)
        let note = try XCTUnwrap(store.createNote(title: "Sized", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let content = try XCTUnwrap(window.contentView)
        XCTAssertEqual(content.frame.width, 720, accuracy: 1, "window should adopt the remembered width")
        XCTAssertEqual(content.frame.height, 640, accuracy: 1, "window should adopt the remembered height")
    }

    /// Resizing a note window persists the new size for the next window that opens.
    func testResizePersistsSizeForNextWindow() throws {
        let note = try XCTUnwrap(store.createNote(title: "Resizer", body: "x", category: nil))
        NoteWindowController.show(note: note)
        let window = try window(for: note)

        window.setContentSize(NSSize(width: 555, height: 480))
        // setContentSize alone doesn't post NSWindow.didResizeNotification synchronously in
        // a headless test, so nudge the delegate the way a live drag would.
        window.delegate?.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))

        XCTAssertEqual(PreferencesManager.shared.noteWindowSize.width, 555, accuracy: 1)
        XCTAssertEqual(PreferencesManager.shared.noteWindowSize.height, 480, accuracy: 1)
    }

    // MARK: - Navigation panel

    func testNoteWindowHostsNavigatorAndEditorInSplitView() throws {
        let note = try XCTUnwrap(store.createNote(title: "Split", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertEqual(split.splitViewItems.count, 2)
        XCTAssertTrue(split.splitViewItems[0].viewController is NoteNavigatorViewController,
                      "the navigator should be the leading (sidebar) item")
        XCTAssertNotNil(window.noteEditor, "the editor should still be reachable from the window")
    }

    func testNavigatorIsHiddenByDefault() throws {
        let note = try XCTUnwrap(store.createNote(title: "Hidden Panel", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let controller = try XCTUnwrap(window.windowController as? NoteWindowController)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        XCTAssertFalse(controller.isNavigatorVisible, "the panel should start hidden")
        XCTAssertTrue(split.splitViewItems[0].isCollapsed, "the sidebar item should start collapsed")
    }

    func testNavigatorButtonTogglesVisibility() throws {
        let note = try XCTUnwrap(store.createNote(title: "Toggle Panel", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let controller = try XCTUnwrap(window.windowController as? NoteWindowController)
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        let editor = try XCTUnwrap(window.noteEditor)
        let button = try XCTUnwrap(navigatorButton(in: editor.view))

        button.performClick(nil)
        XCTAssertTrue(controller.isNavigatorVisible, "clicking should reveal the panel")
        // The collapse itself animates, so let it settle before checking the split view.
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertFalse(split.splitViewItems[0].isCollapsed)

        button.performClick(nil)
        XCTAssertFalse(controller.isNavigatorVisible, "clicking again should hide the panel")
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertTrue(split.splitViewItems[0].isCollapsed)
    }

    /// The View menu item (⌃⌘S) reaches the window through the responder chain, and its title
    /// tracks the panel's state.
    func testMenuActionTogglesNavigatorAndUpdatesTitle() throws {
        let note = try XCTUnwrap(store.createNote(title: "Menu Toggle", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let controller = try XCTUnwrap(window.windowController as? NoteWindowController)
        let item = NSMenuItem(title: "Show Notes Panel", action: #selector(NoteWindowController.toggleNoteNavigator(_:)), keyEquivalent: "")

        XCTAssertTrue(controller.validateMenuItem(item))
        XCTAssertEqual(item.title, "Show Notes Panel")

        controller.toggleNoteNavigator(nil)
        XCTAssertTrue(controller.isNavigatorVisible)
        _ = controller.validateMenuItem(item)
        XCTAssertEqual(item.title, "Hide Notes Panel", "the menu should offer the opposite action once open")

        controller.toggleNoteNavigator(nil)
        XCTAssertFalse(controller.isNavigatorVisible)
    }

    func testSelectingNoteInNavigatorRetargetsSameWindow() throws {
        let first = try XCTUnwrap(store.createNote(title: "First Note", body: "first body", category: nil))
        let second = try XCTUnwrap(store.createNote(title: "Second Note", body: "second body", category: nil))
        NoteWindowController.show(note: first)

        let window = try window(for: first)
        let windowCount = noteWindows().count
        try revealNavigator(in: window)
        try selectInNavigator(second, in: window)

        XCTAssertEqual(noteWindows().count, windowCount, "retargeting must not open another window")
        XCTAssertEqual(window.title, second.title, "the window should retitle to the selected note")
        // Specifically the body view: the title field's field editor is also an NSTextView.
        let textView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: try XCTUnwrap(window.noteEditor).view))
        XCTAssertEqual(textView.string, "second body", "the editor should show the selected note")
    }

    func testRetargetingSavesPendingEditsToPreviousNote() throws {
        let first = try XCTUnwrap(store.createNote(title: "Keeps Edits", body: "start", category: nil))
        let second = try XCTUnwrap(store.createNote(title: "Other Note", body: "other", category: nil))
        NoteWindowController.show(note: first)

        let window = try window(for: first)
        let editor = try XCTUnwrap(window.noteEditor)
        editor.perform(Selector(("toggleMode"))) // into edit mode
        let textView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: editor.view))
        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.insertText(" more", replacementRange: textView.selectedRange())

        try revealNavigator(in: window)
        try selectInNavigator(second, in: window)

        XCTAssertEqual(store.body(of: first), "start more", "the pending edit should be saved to the note we left")
        XCTAssertTrue(textView.string.contains("other"), "the editor should now show the selected note")
    }

    /// The "fix #1" invariant (a typed-but-uncommitted title is never dropped) extended to
    /// switching notes from the panel.
    func testRetargetingCommitsPendingTitleEdit() throws {
        let first = try XCTUnwrap(store.createNote(title: "Original", body: "body", category: nil))
        let second = try XCTUnwrap(store.createNote(title: "Target Note", body: "target", category: nil))
        NoteWindowController.show(note: first)

        let window = try window(for: first)
        let editor = try XCTUnwrap(window.noteEditor)
        let titleField = try XCTUnwrap(firstTitleField(in: editor.view))
        titleField.stringValue = "Renamed Title" // typed, not committed

        try revealNavigator(in: window)
        try selectInNavigator(second, in: window)

        let notes = store.allNotes()
        XCTAssertTrue(notes.contains { $0.title == "renamed-title" }, "the typed title should survive the switch")
        XCTAssertFalse(notes.contains { $0.title == "original" }, "the old title should be gone")
        XCTAssertEqual(window.title, second.title, "the window should end up on the selected note")
    }

    func testRetargetingClearsUndoHistory() throws {
        let first = try XCTUnwrap(store.createNote(title: "Undo Source", body: "start", category: nil))
        let second = try XCTUnwrap(store.createNote(title: "Undo Target", body: "target", category: nil))
        NoteWindowController.show(note: first)

        let window = try window(for: first)
        let editor = try XCTUnwrap(window.noteEditor)
        editor.perform(Selector(("toggleMode")))
        let textView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: editor.view))
        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.insertText(" more", replacementRange: textView.selectedRange())
        XCTAssertTrue(editor.noteUndoManager.canUndo)

        try revealNavigator(in: window)
        try selectInNavigator(second, in: window)

        XCTAssertFalse(editor.noteUndoManager.canUndo, "switching notes must not leave undo actions from the old one")
    }

    /// One window per note: selecting a note that already has its own window fronts that window
    /// instead of moving the note into this one.
    func testRetargetingDoesNotStealNoteFromAnotherWindow() throws {
        let first = try XCTUnwrap(store.createNote(title: "Owner One", body: "one", category: nil))
        let second = try XCTUnwrap(store.createNote(title: "Owner Two", body: "two", category: nil))
        NoteWindowController.show(note: first)
        NoteWindowController.show(note: second)

        let firstWindow = try window(for: first)
        let windowCount = noteWindows().count
        try revealNavigator(in: firstWindow)
        try selectInNavigator(second, in: firstWindow)

        XCTAssertEqual(firstWindow.title, first.title, "the first window should keep its own note")
        XCTAssertEqual(noteWindows().count, windowCount, "no window should be opened or closed")
    }

    func testSelectingDeletedNoteLeavesWindowUnchanged() throws {
        let first = try XCTUnwrap(store.createNote(title: "Survivor", body: "one", category: nil))
        let second = try XCTUnwrap(store.createNote(title: "Doomed", body: "two", category: nil))
        NoteWindowController.show(note: first)

        let window = try window(for: first)
        try revealNavigator(in: window)
        // Delete behind the panel's back (no store notification) so the stale row survives.
        try FileManager.default.removeItem(at: second.url)
        try selectInNavigator(second, in: window, expectRow: true)

        XCTAssertEqual(window.title, first.title, "a vanished note must not replace the open one")
    }

    /// Click the header button and let the collapse animation settle, so the panel's list is
    /// loaded and its rows exist.
    private func revealNavigator(in window: NSWindow) throws {
        let editor = try XCTUnwrap(window.noteEditor)
        try XCTUnwrap(navigatorButton(in: editor.view)).performClick(nil)
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
    }

    /// Drive the panel's list the way a click would: select the row for `note` and let the
    /// selection debounce fire.
    private func selectInNavigator(_ note: Note, in window: NSWindow, expectRow: Bool = true) throws {
        let split = try XCTUnwrap(window.contentViewController as? NSSplitViewController)
        let navigator = try XCTUnwrap(split.splitViewItems[0].viewController as? NoteNavigatorViewController)
        let outline = try XCTUnwrap(firstView(NSOutlineView.self, in: navigator.view))

        // Match on file name, not standardized URL: standardizing only resolves /var into
        // /private/var while the file still exists, so a deleted note would never match.
        var target = -1
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? NoteNavigatorNode,
                  node.note?.url.lastPathComponent == note.url.lastPathComponent else { continue }
            target = row
            break
        }
        if expectRow { XCTAssertGreaterThanOrEqual(target, 0, "the note should have a row in the panel") }
        guard target >= 0 else { return }

        outline.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
        navigator.outlineViewSelectionDidChange(
            Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        RunLoop.current.run(until: Date().addingTimeInterval(0.3)) // past the selection debounce
    }

    /// The header's navigation-panel button, identified by its action selector.
    private func navigatorButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.action == Selector(("toggleNavigator")) { return button }
        for sub in view.subviews {
            if let button = navigatorButton(in: sub) { return button }
        }
        return nil
    }

    /// Recursively locate the first view of a given type in a hierarchy.
    private func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = firstView(type, in: sub) { return match }
        }
        return nil
    }

    /// The header's pin (keep-on-top) button, identified by its action selector.
    private func pinButton(in view: NSView) -> NSButton? {
        if let button = view as? NSButton, button.action == Selector(("togglePin")) { return button }
        for sub in view.subviews {
            if let button = pinButton(in: sub) { return button }
        }
        return nil
    }

    /// The editable, bezeled title field (distinct from label text fields).
    private func firstTitleField(in view: NSView) -> NSTextField? {
        if let field = view as? NSTextField, field.isEditable, field.isBezeled { return field }
        for sub in view.subviews {
            if let field = firstTitleField(in: sub) { return field }
        }
        return nil
    }
}
