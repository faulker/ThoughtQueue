import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers checkbox toggling in the *markdown* note editor: prose notes that merely contain some
/// `- [ ]` lines keep the rendered text view with clickable boxes. Notes that are entirely a list
/// get the dedicated checklist editor instead, covered by `ChecklistEditorTests`, so the bodies
/// here deliberately include a prose line.
final class TaskToggleTests: XCTestCase {
    private var tempRoot: URL!
    private var savedEditMode: NoteEditMode!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-task-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
        savedEditMode = PreferencesManager.shared.noteEditMode
    }

    override func tearDownWithError() throws {
        PreferencesManager.shared.noteEditMode = savedEditMode
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    /// Build a loaded editor for a note with `body`, as the note window would.
    private func makeEditor(body: String, startInEditMode: Bool = false) throws -> (NoteEditorViewController, Note) {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "List", body: body, category: nil))
        let vc = NoteEditorViewController(note: note, startInEditMode: startInEditMode)
        _ = vc.view // force viewDidLoad
        return (vc, note)
    }

    // MARK: - Toggling

    func testTogglingASourceLineWritesTheFile() throws {
        // Prose keeps this a markdown note, so it uses the rendered text view rather than the
        // checklist editor (which has its own coverage in ChecklistEditorTests).
        let (vc, note) = try makeEditor(body: "notes\n\n- [ ] one\n- [x] two\n")

        XCTAssertTrue(vc.toggleTask(onSourceLine: 2))

        XCTAssertEqual(NoteStore.shared.body(of: note), "notes\n\n- [x] one\n- [x] two\n")
    }

    func testTogglingIsReversible() throws {
        let (vc, note) = try makeEditor(body: "notes\n- [ ] one\n")

        XCTAssertTrue(vc.toggleTask(onSourceLine: 1))
        XCTAssertTrue(vc.toggleTask(onSourceLine: 1))

        XCTAssertEqual(NoteStore.shared.body(of: note), "notes\n- [ ] one\n")
    }

    func testTogglingANonTaskLineIsANoOp() throws {
        let body = "notes\n\n- [ ] one\n"
        let (vc, note) = try makeEditor(body: body)

        XCTAssertFalse(vc.toggleTask(onSourceLine: 0))

        XCTAssertEqual(NoteStore.shared.body(of: note), body)
    }

    /// The staleness guard: if the file changed since we rendered, the stamped line indices no
    /// longer describe it, so the toggle must resync rather than write to a guessed line.
    func testStaleRenderIsResyncedInsteadOfToggled() throws {
        let (vc, note) = try makeEditor(body: "notes\n- [ ] one\n- [ ] two\n")

        let behindOurBack = "notes\n- [ ] inserted\n- [ ] one\n- [ ] two\n"
        try behindOurBack.write(to: note.url, atomically: true, encoding: .utf8)

        XCTAssertFalse(vc.toggleTask(onSourceLine: 0))
        XCTAssertEqual(NoteStore.shared.body(of: note), behindOurBack)
    }

    func testTogglingIsRefusedWhileEditingRawMarkdown() throws {
        let body = "notes\n- [ ] one\n"
        let (vc, note) = try makeEditor(body: body, startInEditMode: true)

        XCTAssertTrue(vc.isEditing)
        XCTAssertFalse(vc.toggleTask(onSourceLine: 0))
        XCTAssertEqual(NoteStore.shared.body(of: note), body)
    }

    // MARK: - Presentation

    func testAlwaysEditStillAppliesToProseNotes() throws {
        PreferencesManager.shared.noteEditMode = .alwaysEdit

        let (prose, _) = try makeEditor(body: "just some prose\n")
        XCTAssertTrue(prose.isEditing, "a prose note should still honor always-edit")
    }

    func testNewProseNoteStillOpensInEditModeSoItCanBeTyped() throws {
        let (vc, _) = try makeEditor(body: "", startInEditMode: true)
        XCTAssertTrue(vc.isEditing)
    }

    // MARK: - Return key

    func testReturnContinuesATaskList() throws {
        let (vc, _) = try makeEditor(body: "notes\n- [ ] one", startInEditMode: true)
        vc.textView.setSelectedRange(NSRange(location: (vc.textView.string as NSString).length, length: 0))

        XCTAssertTrue(vc.continueTaskList())

        XCTAssertEqual(vc.textView.string, "notes\n- [ ] one\n- [ ] ")
    }

    func testReturnOnAnEmptyItemClearsTheMarker() throws {
        let (vc, _) = try makeEditor(body: "notes\n- [ ] one\n- [ ] ", startInEditMode: true)
        vc.textView.setSelectedRange(NSRange(location: (vc.textView.string as NSString).length, length: 0))

        XCTAssertTrue(vc.continueTaskList())

        XCTAssertEqual(vc.textView.string, "notes\n- [ ] one\n")
    }

    func testReturnOnProseIsNotHandled() throws {
        let (vc, _) = try makeEditor(body: "just prose", startInEditMode: true)
        vc.textView.setSelectedRange(NSRange(location: (vc.textView.string as NSString).length, length: 0))

        XCTAssertFalse(vc.continueTaskList())

        XCTAssertEqual(vc.textView.string, "just prose")
    }

    // MARK: - Hit testing

    /// Build a read-only text view showing `markdown`, laid out at a usable width.
    private func makeRenderedTextView(_ markdown: String) -> ModeSwitchingTextView {
        let textView = ModeSwitchingTextView(usingTextLayoutManager: false)
        textView.frame = NSRect(x: 0, y: 0, width: 400, height: 400)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.containerSize = NSSize(width: 388, height: CGFloat.greatestFiniteMagnitude)
        textView.textContainer?.widthTracksTextView = false
        textView.isEditable = false
        textView.textStorage?.setAttributedString(MarkdownRenderer.render(markdown))
        if let container = textView.textContainer { textView.layoutManager?.ensureLayout(for: container) }
        return textView
    }

    /// Center point (view coordinates) of the character at `index`.
    private func point(at index: Int, in textView: ModeSwitchingTextView) throws -> NSPoint {
        let layoutManager = try XCTUnwrap(textView.layoutManager)
        let container = try XCTUnwrap(textView.textContainer)
        let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: index, length: 1),
                                                  actualCharacterRange: nil)
        let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: container)
        return NSPoint(x: rect.midX + textView.textContainerInset.width,
                       y: rect.midY + textView.textContainerInset.height)
    }

    func testClickingTheCheckboxGlyphHitsTheRightSourceLine() throws {
        let textView = makeRenderedTextView("- [ ] one\n- [ ] two")

        // Character 0 is the first item's gutter; the second item starts after "  \u{2610} one\n".
        let first = try XCTUnwrap(textView.taskHit(at: try point(at: 0, in: textView)))
        XCTAssertEqual(first.sourceLine, 0)
        XCTAssertTrue(first.isCheckbox)

        let secondGutter = ("  \u{2610} one\n" as NSString).length
        let second = try XCTUnwrap(textView.taskHit(at: try point(at: secondGutter, in: textView)))
        XCTAssertEqual(second.sourceLine, 1)
        XCTAssertTrue(second.isCheckbox)
    }

    /// The guard that stops a click in the empty space below the list toggling the last item.
    func testClickingBelowTheLastItemIsNotAHit() throws {
        let textView = makeRenderedTextView("- [ ] one\n- [ ] two")
        XCTAssertNil(textView.taskHit(at: NSPoint(x: 20, y: 380)))
    }

    func testItemTextIsOnlyAHitInChecklistMode() throws {
        let textView = makeRenderedTextView("- [ ] one\n- [ ] two")
        // Inside the word "one", past the 4-character gutter.
        let textPoint = try point(at: 5, in: textView)

        textView.togglesWholeTaskLine = false
        XCTAssertNil(textView.taskHit(at: textPoint))

        textView.togglesWholeTaskLine = true
        let hit = try XCTUnwrap(textView.taskHit(at: textPoint))
        XCTAssertEqual(hit.sourceLine, 0)
        XCTAssertFalse(hit.isCheckbox, "item text is not the box run")
    }

    /// The regression the source-line attribute exists for: a table above shifts rendered
    /// position away from source line, and the click must still land on the right line.
    func testCheckboxAfterATableStillMapsToItsSourceLine() throws {
        let markdown = "| A | B |\n| --- | --- |\n| 1 | 2 |\n\n- [ ] task"
        let textView = makeRenderedTextView(markdown)

        let gutter = (textView.string as NSString).range(of: "\u{2610}").location - 2
        let hit = try XCTUnwrap(textView.taskHit(at: try point(at: gutter, in: textView)))
        XCTAssertEqual(hit.sourceLine, 4)
    }

    func testHitTestingIsInertWhileEditing() throws {
        let textView = makeRenderedTextView("- [ ] one")
        let boxPoint = try point(at: 0, in: textView)
        XCTAssertNotNil(textView.taskHit(at: boxPoint))

        textView.isEditable = true
        XCTAssertNil(textView.taskHit(at: boxPoint), "raw markdown has no checkboxes to hit")
    }

    // MARK: - Toggle Task shortcut

    func testToggleTaskMarkerPromotesTheCaretLine() throws {
        let (vc, _) = try makeEditor(body: "buy milk", startInEditMode: true)
        vc.textView.setSelectedRange(NSRange(location: 3, length: 0))

        vc.toggleTaskMarker(nil)

        XCTAssertEqual(vc.textView.string, "- [ ] buy milk")
    }

    func testToggleTaskMarkerFlipsAnExistingTaskOnTheCaretLine() throws {
        let (vc, _) = try makeEditor(body: "notes\n- [ ] one\n- [ ] two", startInEditMode: true)
        vc.textView.setSelectedRange(NSRange(location: (vc.textView.string as NSString).length, length: 0))

        vc.toggleTaskMarker(nil)

        XCTAssertEqual(vc.textView.string, "notes\n- [ ] one\n- [x] two")
    }

    func testToggleTaskMarkerIsANoOpInViewMode() throws {
        let (vc, _) = try makeEditor(body: "notes\n- [ ] one\n")
        XCTAssertFalse(vc.isEditing)

        vc.toggleTaskMarker(nil)

        XCTAssertEqual(NoteStore.shared.body(of: vc.currentNote), "notes\n- [ ] one\n")
    }

    func testReturnMidItemSplitsInsteadOfContinuing() throws {
        let (vc, _) = try makeEditor(body: "notes\n- [ ] one", startInEditMode: true)
        vc.textView.setSelectedRange(NSRange(location: 2, length: 0))

        XCTAssertFalse(vc.continueTaskList())
    }
}
