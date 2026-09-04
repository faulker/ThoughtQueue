import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers the checklist editor: which notes get it, that a box always writes through, and that
/// a list note is never presented as a markdown document.
final class ChecklistEditorTests: XCTestCase {
    private var tempRoot: URL!
    private var savedEditMode: NoteEditMode!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-checklist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
        savedEditMode = PreferencesManager.shared.noteEditMode
    }

    override func tearDownWithError() throws {
        PreferencesManager.shared.noteEditMode = savedEditMode
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    private func makeEditor(body: String, startInEditMode: Bool = false,
                            docType: NoteDocType? = .checklist) throws -> (NoteEditorViewController, Note) {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "List", body: body,
                                                             category: nil, docType: docType))
        let vc = NoteEditorViewController(note: note, startInEditMode: startInEditMode)
        _ = vc.view
        return (vc, note)
    }

    // MARK: - Which notes become checklists

    func testChecklistNoteOpensAsAChecklist() throws {
        let (vc, _) = try makeEditor(body: "- [ ] one\n- [x] two\n")
        XCTAssertEqual(vc.contentMode, .checklist)
        XCTAssertFalse(vc.isEditing)
    }

    /// The bug that prompted this: "+ List" created a note that opened as raw markdown, where
    /// the checkbox was literal text and could not be clicked.
    func testNewListOpensAsAChecklistNotRawMarkdown() throws {
        let (vc, _) = try makeEditor(body: TaskList.newItemPrefix, startInEditMode: true)
        XCTAssertEqual(vc.contentMode, .checklist)
        XCTAssertFalse(vc.isEditing, "a new list must not open as a markdown document")
        XCTAssertEqual(vc.checklist.rows.count, 1)
    }

    func testListsIgnoreTheNoteEditModePreferenceEntirely() throws {
        for mode in [NoteEditMode.doubleClick, .singleClick, .alwaysEdit] {
            PreferencesManager.shared.noteEditMode = mode
            let (vc, _) = try makeEditor(body: "- [ ] one\n")
            XCTAssertEqual(vc.contentMode, .checklist, "preference \(mode) leaked into a list note")
        }
    }

    /// Content never promotes a note to a list, whatever it happens to hold: a scratch note of
    /// nothing but `- [ ]` lines is as much a markdown document as a page of prose.
    func testNoContentTurnsAnUndeclaredNoteIntoAChecklist() throws {
        for body in ["just prose\n", "- [ ] one\nsome prose\n", "", "# Groceries\n",
                     "- [ ] one\n- [x] two\n"] {
            let (vc, _) = try makeEditor(body: body, docType: nil)
            XCTAssertNotEqual(vc.contentMode, .checklist, "body \(body.debugDescription) became a list")
        }
    }

    /// And a declared list stays one whatever it holds, including nothing.
    func testADeclaredListIsAChecklistWhateverItHolds() throws {
        for body in ["", "# Groceries\n", "- [ ] one\nsome prose\n"] {
            let (vc, _) = try makeEditor(body: body)
            XCTAssertEqual(vc.contentMode, .checklist, "body \(body.debugDescription) stopped being a list")
        }
    }

    func testAVeryLongListFallsBackToRenderedMarkdown() throws {
        let body = (0..<(ChecklistViewController.maxRows + 10)).map { "- [ ] item \($0)" }.joined(separator: "\n")
        let (vc, _) = try makeEditor(body: body)
        XCTAssertEqual(vc.contentMode, .rendered, "too many rows for live controls")
    }

    func testHeadingsAreRowsInTheChecklist() throws {
        let (vc, _) = try makeEditor(body: "# Groceries\n\n- [ ] milk\n")
        XCTAssertEqual(vc.contentMode, .checklist)
        XCTAssertEqual(vc.checklist.rows.count, 4)   // heading, blank, task, trailing blank
    }

    // MARK: - Toggling

    func testTogglingARowWritesImmediately() throws {
        let (vc, note) = try makeEditor(body: "# T\n\n- [ ] one\n- [x] two\n")

        XCTAssertTrue(vc.checklist.toggleRow(at: 2))

        XCTAssertEqual(NoteStore.shared.body(of: note), "# T\n\n- [x] one\n- [x] two\n")
    }

    func testTogglingIsReversibleAndLeavesEveryOtherByteAlone() throws {
        let body = "\t  * [ ]   spaced   text  \n- [ ] plain\n"
        let (vc, note) = try makeEditor(body: body)

        XCTAssertTrue(vc.checklist.toggleRow(at: 0))
        XCTAssertEqual(NoteStore.shared.body(of: note), "\t  * [x]   spaced   text  \n- [ ] plain\n")

        XCTAssertTrue(vc.checklist.toggleRow(at: 0))
        XCTAssertEqual(NoteStore.shared.body(of: note), body)
    }

    func testTogglingANonTaskRowDoesNothing() throws {
        let body = "# T\n- [ ] one\n"
        let (vc, note) = try makeEditor(body: body)

        XCTAssertFalse(vc.checklist.toggleRow(at: 0))
        XCTAssertEqual(NoteStore.shared.body(of: note), body)
    }

    func testExternalChangeIsNotClobbered() throws {
        let (vc, note) = try makeEditor(body: "- [ ] one\n- [ ] two\n")

        let behindOurBack = "- [ ] inserted\n- [ ] one\n- [ ] two\n"
        try behindOurBack.write(to: note.url, atomically: true, encoding: .utf8)

        _ = vc.checklist.toggleRow(at: 0)

        XCTAssertEqual(NoteStore.shared.body(of: note), behindOurBack,
                       "a stale row index must never overwrite a newer file")
    }

    // MARK: - The "+ List" path, end to end

    /// The exact flow the popover's "+ List" button runs, through the real window controller.
    /// This is the reported bug: the new note opened as markdown with an unclickable checkbox.
    func testPlusListOpensAWindowShowingAClickableChecklist() throws {
        let note = try XCTUnwrap(NoteWindowController.showNew(body: TaskList.newItemPrefix,
                                                              docType: .checklist))
        defer { NoteWindowController.closeAllForTesting() }

        let window = try XCTUnwrap(NSApp.windows.first { $0.noteEditor?.currentNote.url == note.url })
        let editor = try XCTUnwrap(window.noteEditor)

        XCTAssertEqual(editor.contentMode, .checklist, "a new list must not open as markdown")
        XCTAssertEqual(editor.checklist.rows.count, 1)

        // And the box is live: toggling writes straight through to the file.
        XCTAssertTrue(editor.checklist.toggleRow(at: 0))
        XCTAssertEqual(NoteStore.shared.body(of: note), "- [x] ")
    }

    // MARK: - Keyboard

    /// Drive `control(_:textView:doCommandBy:)` with a detached text view so the caret position
    /// is exact. A real field editor needs a key window, which GitHub's macOS runners do not
    /// give the test host.
    @discardableResult
    private func sendCommand(_ selector: Selector, toRow index: Int, offset: Int,
                             in vc: NoteEditorViewController) -> Bool {
        guard let field = vc.checklist.fieldForTesting(at: index) else { return false }
        let editor = NSTextView(frame: .zero)
        editor.string = field.stringValue
        let clamped = min(max(offset, 0), (editor.string as NSString).length)
        editor.selectedRange = NSRange(location: clamped, length: 0)
        return vc.checklist.control(field, textView: editor, doCommandBy: selector)
    }

    func testReturnAtEndOfAnItemAddsTheNextOne() throws {
        let (vc, note) = try makeEditor(body: "- [ ] milk\n")

        XCTAssertTrue(sendCommand(#selector(NSResponder.insertNewline(_:)), toRow: 0, offset: 4, in: vc))

        XCTAssertEqual(TaskList.body(from: vc.checklist.rows), "- [ ] milk\n- [ ] \n")
        vc.flushChecklist()
        XCTAssertEqual(NoteStore.shared.body(of: note), "- [ ] milk\n- [ ] \n")
    }

    func testReturnMidItemSplitsIt() throws {
        let (vc, _) = try makeEditor(body: "- [ ] milkbread\n")

        sendCommand(#selector(NSResponder.insertNewline(_:)), toRow: 0, offset: 4, in: vc)

        XCTAssertEqual(TaskList.body(from: vc.checklist.rows), "- [ ] milk\n- [ ] bread\n")
    }

    func testReturnOnAnEmptyItemEndsTheList() throws {
        let (vc, _) = try makeEditor(body: "- [ ] milk\n- [ ] \n")

        sendCommand(#selector(NSResponder.insertNewline(_:)), toRow: 1, offset: 0, in: vc)

        XCTAssertEqual(TaskList.body(from: vc.checklist.rows), "- [ ] milk\n")
    }

    func testBackspaceAtStartOfANonEmptyItemMergesItUp() throws {
        let (vc, _) = try makeEditor(body: "- [ ] milk\n- [ ] bread\n")

        sendCommand(#selector(NSResponder.deleteBackward(_:)), toRow: 1, offset: 0, in: vc)

        XCTAssertEqual(TaskList.body(from: vc.checklist.rows), "- [ ] milkbread\n")
    }

    func testBackspaceMidTextIsLeftToTheFieldEditor() throws {
        let (vc, _) = try makeEditor(body: "- [ ] milk\n")

        XCTAssertFalse(sendCommand(#selector(NSResponder.deleteBackward(_:)), toRow: 0, offset: 2, in: vc),
                       "ordinary deletion inside an item must not be intercepted")
    }

    func testTypingIntoAnItemPersists() throws {
        let (vc, note) = try makeEditor(body: "- [ ] \n")
        let field = try XCTUnwrap(vc.checklist.fieldForTesting(at: 0))
        field.stringValue = "milk"
        vc.checklist.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification,
                                                           object: field))

        XCTAssertEqual(NoteStore.shared.body(of: note), "- [ ] milk\n")
    }

    // MARK: - Escape hatch

    func testEditAsMarkdownSwitchesToRawAndBack() throws {
        let body = "- [ ] one\n"
        let (vc, _) = try makeEditor(body: body)
        XCTAssertEqual(vc.contentMode, .checklist)

        vc.toggleChecklistMarkdown(nil)
        XCTAssertEqual(vc.contentMode, .raw)
        XCTAssertEqual(vc.textView.string, body)

        vc.toggleChecklistMarkdown(nil)
        XCTAssertEqual(vc.contentMode, .checklist)
    }

    func testMarkdownSessionEndsWhenTheWindowRetargets() throws {
        let (vc, _) = try makeEditor(body: "- [ ] one\n")
        vc.toggleChecklistMarkdown(nil)
        XCTAssertTrue(vc.forceMarkdownForSession)

        let other = try XCTUnwrap(NoteStore.shared.createNote(title: "Other", body: "- [ ] a\n",
                                                              category: nil, docType: .checklist))
        vc.load(note: other)

        XCTAssertFalse(vc.forceMarkdownForSession)
        XCTAssertEqual(vc.contentMode, .checklist)
    }

    func testMenuItemTitleAndEnablement() throws {
        let (vc, _) = try makeEditor(body: "- [ ] one\n")
        let item = NSMenuItem(title: "", action: Selector(("toggleChecklistMarkdown:")), keyEquivalent: "")

        XCTAssertTrue(vc.validateMenuItem(item))
        XCTAssertEqual(item.title, "Edit as Markdown")

        vc.toggleChecklistMarkdown(nil)
        XCTAssertTrue(vc.validateMenuItem(item))
        XCTAssertEqual(item.title, "Edit as Checklist")
    }

    func testProseNoteDoesNotOfferTheChecklistCommand() throws {
        let (vc, _) = try makeEditor(body: "just prose\n", docType: .markdown)
        let item = NSMenuItem(title: "", action: Selector(("toggleChecklistMarkdown:")), keyEquivalent: "")
        XCTAssertFalse(vc.validateMenuItem(item))
    }
}

/// Moving a list note between categories used to leave the window blank until it was reopened:
/// `NoteStore.move` posts `.notesDidChange` before the editor has adopted the new URL, and the
/// checklist resynced itself against a path that no longer existed.
final class ChecklistCategoryMoveTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    private func makeEditor(body: String) throws -> (NoteEditorViewController, Note) {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "List", body: body,
                                                             category: nil, docType: .checklist))
        let vc = NoteEditorViewController(note: note, startInEditMode: false)
        _ = vc.view
        return (vc, note)
    }

    func testChangingCategoryKeepsTheChecklistOnScreen() throws {
        let (vc, _) = try makeEditor(body: "- [ ] one\n- [x] two\n")
        XCTAssertEqual(vc.contentMode, .checklist)

        vc.performMove(to: "Work")

        XCTAssertEqual(vc.contentMode, .checklist, "the list must survive a category change")
        XCTAssertEqual(vc.checklist.rows.filter(\.isTask).count, 2)
        XCTAssertEqual(vc.currentNote.category, "Work")
        XCTAssertFalse(vc.checklist.view.isHidden)
    }

    func testChangingCategoryTwiceStillKeepsTheChecklist() throws {
        let (vc, _) = try makeEditor(body: "- [ ] one\n")
        vc.performMove(to: "Work")
        vc.performMove(to: nil)

        XCTAssertEqual(vc.contentMode, .checklist)
        XCTAssertEqual(vc.checklist.rows.filter(\.isTask).count, 1)
        XCTAssertNil(vc.currentNote.category)
    }

    /// The raw notification path on its own: the store posts while the editor's note still
    /// names the old, now-missing file.
    func testAChangeNotificationForAMissingFileDoesNotBlankTheList() throws {
        let (vc, note) = try makeEditor(body: "- [ ] one\n")
        _ = NoteStore.shared.move(note, to: "Work")

        XCTAssertEqual(vc.contentMode, .checklist)
        XCTAssertEqual(vc.checklist.rows.filter(\.isTask).count, 1)
    }

    /// The move carries the recorded document type with the file, so the note is still a list
    /// in its new folder.
    func testDocumentTypeFollowsTheNoteAcrossCategories() throws {
        let (vc, _) = try makeEditor(body: "- [ ] one\n")
        vc.performMove(to: "Work")
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: vc.currentNote.url), .checklist)
    }
}

/// Covers the editor side of the recorded document type: a note opens as what it was declared
/// to be, not as whatever its first line currently looks like.
final class NoteDocumentTypeEditorTests: XCTestCase {
    private var tempRoot: URL!
    private var savedEditMode: NoteEditMode!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-doctype-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
        savedEditMode = PreferencesManager.shared.noteEditMode
        PreferencesManager.shared.noteEditMode = .doubleClick
    }

    override func tearDownWithError() throws {
        PreferencesManager.shared.noteEditMode = savedEditMode
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    private func editor(for note: Note) -> NoteEditorViewController {
        let vc = NoteEditorViewController(note: note, startInEditMode: false)
        _ = vc.view
        return vc
    }

    /// The reported bug: a checkbox typed as the first line of an ordinary note silently made
    /// it a checklist the next time it opened.
    func testAMarkdownNoteFullOfCheckboxesStillOpensAsMarkdown() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Notes", body: "",
                                                             category: nil, docType: .markdown))
        XCTAssertTrue(NoteStore.shared.updateBody(of: note, body: "- [ ] milk\n"))
        XCTAssertNotEqual(editor(for: note).contentMode, .checklist)
    }

    func testADeclaredListOpensAsAChecklistEvenWithProseInIt() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "List", body: "- [ ] one\n",
                                                             category: nil, docType: .checklist))
        XCTAssertTrue(NoteStore.shared.updateBody(of: note, body: "- [ ] one\nsome prose\n"))
        XCTAssertEqual(editor(for: note).contentMode, .checklist)
    }

    /// A note from before document types existed, or one dropped into the folder by hand, is a
    /// markdown document even when every line is a checkbox. Its boxes are still clickable in
    /// the rendered view, and one "Edit as Checklist" makes it a list for good.
    func testANoteWithNoRecordedTypeOpensAsMarkdown() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Legacy", body: "- [ ] one\n",
                                                             category: nil))
        XCTAssertNotEqual(editor(for: note).contentMode, .checklist)
    }

    func testEditAsMarkdownRecordsTheChoicePermanently() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "List", body: "- [ ] one\n",
                                                             category: nil, docType: .checklist))
        let vc = editor(for: note)
        vc.toggleChecklistMarkdown(nil)

        XCTAssertEqual(NoteMetadataStore.shared.docType(for: note.url), .markdown)
        // A freshly opened window on the same note honours the recorded choice.
        XCTAssertNotEqual(editor(for: note).contentMode, .checklist)
    }

    func testEditAsChecklistConvertsAMarkdownNoteBack() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Notes", body: "- [ ] one\n",
                                                             category: nil, docType: .markdown))
        let vc = editor(for: note)
        XCTAssertNotEqual(vc.contentMode, .checklist)

        vc.toggleChecklistMarkdown(nil)

        XCTAssertEqual(vc.contentMode, .checklist)
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: note.url), .checklist)
    }

    /// A markdown note whose body would work as a list still offers the conversion.
    func testConversionIsOfferedOnAMarkdownNoteOfTasks() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Notes", body: "- [ ] one\n",
                                                             category: nil, docType: .markdown))
        let item = NSMenuItem(title: "", action: Selector(("toggleChecklistMarkdown:")), keyEquivalent: "")
        XCTAssertTrue(editor(for: note).validateMenuItem(item))
        XCTAssertEqual(item.title, "Edit as Checklist")
    }
}
