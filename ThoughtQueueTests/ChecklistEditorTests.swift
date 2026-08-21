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

    private func makeEditor(body: String, startInEditMode: Bool = false) throws -> (NoteEditorViewController, Note) {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "List", body: body, category: nil))
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

    func testProseAndMixedNotesDoNotGetTheChecklist() throws {
        let (prose, _) = try makeEditor(body: "just prose\n")
        XCTAssertNotEqual(prose.contentMode, .checklist)

        let (mixed, _) = try makeEditor(body: "- [ ] one\nsome prose\n")
        XCTAssertNotEqual(mixed.contentMode, .checklist)

        let (empty, _) = try makeEditor(body: "")
        XCTAssertNotEqual(empty.contentMode, .checklist)

        let (headingOnly, _) = try makeEditor(body: "# Groceries\n")
        XCTAssertNotEqual(headingOnly.contentMode, .checklist)
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
        let note = try XCTUnwrap(NoteWindowController.showNew(body: TaskList.newItemPrefix))
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

        let other = try XCTUnwrap(NoteStore.shared.createNote(title: "Other", body: "- [ ] a\n", category: nil))
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
        let (vc, _) = try makeEditor(body: "just prose\n")
        let item = NSMenuItem(title: "", action: Selector(("toggleChecklistMarkdown:")), keyEquivalent: "")
        XCTAssertFalse(vc.validateMenuItem(item))
    }
}
