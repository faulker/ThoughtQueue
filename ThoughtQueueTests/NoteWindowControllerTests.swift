import XCTest
@testable import ThoughtQueue

/// Verifies the per-note window behavior: opening the same note twice reuses one window,
/// and the window opens in read-only (view) mode by default.
@MainActor
final class NoteWindowControllerTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!
    private var savedEditMode: NoteEditMode!

    override func setUpWithError() throws {
        closeNoteWindows() // isolate from any windows a prior case left behind
        savedEditMode = PreferencesManager.shared.noteEditMode
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-win-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        closeNoteWindows()
        PreferencesManager.shared.noteEditMode = savedEditMode
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    /// Close every note window and drain the run loop so they leave `NSApp.windows`.
    private func closeNoteWindows() {
        noteWindows().forEach { $0.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func noteWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.contentViewController is NoteEditorViewController }
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
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
        let scrollView = try XCTUnwrap(firstView(NSScrollView.self, in: editor.view))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertFalse(textView.isEditable, "notes should open read-only in view mode by default")
    }

    func testAlwaysEditModeOpensExistingNoteEditable() throws {
        PreferencesManager.shared.noteEditMode = .alwaysEdit
        let note = try XCTUnwrap(store.createNote(title: "Always Edit", body: "# Heading", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
        let scrollView = try XCTUnwrap(firstView(NSScrollView.self, in: editor.view))
        let textView = try XCTUnwrap(scrollView.documentView as? NSTextView)
        XCTAssertTrue(textView.isEditable, "always-edit mode should open existing notes editable")
    }

    func testEditModeControlsSingleClickThreshold() throws {
        PreferencesManager.shared.noteEditMode = .singleClick
        let single = try XCTUnwrap(store.createNote(title: "Single", body: "x", category: nil))
        NoteWindowController.show(note: single)
        let singleView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: try window(for: single).contentViewController!.view))
        XCTAssertTrue(singleView.activatesOnSingleClick, "single-click mode should activate editing on one click")

        PreferencesManager.shared.noteEditMode = .doubleClick
        let double = try XCTUnwrap(store.createNote(title: "Double", body: "x", category: nil))
        NoteWindowController.show(note: double)
        let doubleView = try XCTUnwrap(firstView(ModeSwitchingTextView.self, in: try window(for: double).contentViewController!.view))
        XCTAssertFalse(doubleView.activatesOnSingleClick, "double-click mode should require a double-click")
    }

    func testTitleFieldShowsNoteTitleAndIsEditable() throws {
        let note = try XCTUnwrap(store.createNote(title: "Editable Title", body: "x", category: nil))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
        let titleField = try XCTUnwrap(firstTitleField(in: editor.view))
        XCTAssertEqual(titleField.stringValue, note.title)
        XCTAssertTrue(titleField.isEditable)
    }

    func testCategoryPopupReflectsAndListsCategories() throws {
        _ = try XCTUnwrap(store.createNote(title: "Other", body: "x", category: "Personal"))
        let note = try XCTUnwrap(store.createNote(title: "Work Note", body: "x", category: "Work"))
        NoteWindowController.show(note: note)

        let window = try window(for: note)
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
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
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
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
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
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
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
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
        let editor = try XCTUnwrap(window.contentViewController as? NoteEditorViewController)
        editor.perform(Selector(("toggleMode"))) // into edit mode
        let textView = try XCTUnwrap(firstView(NSTextView.self, in: editor.view))

        textView.selectedRange = NSRange(location: textView.string.count, length: 0)
        textView.insertText(" more", replacementRange: textView.selectedRange())
        XCTAssertTrue(editor.noteUndoManager.canUndo)

        editor.perform(Selector(("toggleMode"))) // back to view mode (saves + reloads)
        XCTAssertFalse(editor.noteUndoManager.canUndo, "leaving edit mode should clear stale undo history")
    }

    /// Recursively locate the first view of a given type in a hierarchy.
    private func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = firstView(type, in: sub) { return match }
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
