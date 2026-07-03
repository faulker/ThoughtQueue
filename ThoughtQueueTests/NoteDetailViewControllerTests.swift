import XCTest
@testable import ThoughtQueue

/// Covers the main-window detail pane: an editable title that renames the note (fix #7), and
/// clearing the pane when the displayed note is deleted (fix #4).
@MainActor
final class NoteDetailViewControllerTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!
    private var priorClickBehavior: ClickBehavior!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-detail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
        priorClickBehavior = PreferencesManager.shared.clickBehavior
        // Render in-app so display() puts the body on screen without running an external command.
        PreferencesManager.shared.clickBehavior = .renderMarkdown
    }

    override func tearDownWithError() throws {
        PreferencesManager.shared.clickBehavior = priorClickBehavior
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    /// Fix #4: deleting the note currently shown clears its text instead of leaving it behind.
    func testDeletingDisplayedNoteClearsPane() throws {
        let note = try XCTUnwrap(store.createNote(title: "ToDelete", body: "secret text", category: nil))
        let vc = NoteDetailViewController()
        _ = vc.view
        vc.display(note)

        let textView = try XCTUnwrap(firstView(NSTextView.self, in: vc.view))
        XCTAssertTrue(textView.string.contains("secret text"))

        _ = store.delete(note)
        // onNotesChanged defers the existence check to the next main-loop turn; pump it.
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))

        XCTAssertEqual(textView.string, "", "the deleted note's text should be cleared")
        let titleField = try XCTUnwrap(firstTitleField(in: vc.view))
        XCTAssertEqual(titleField.stringValue, "", "the title field should clear too")
    }

    /// Fix #7: editing the title field renames the underlying note file.
    func testTitleFieldRenamesNote() throws {
        let note = try XCTUnwrap(store.createNote(title: "OldName", body: "x", category: nil))
        let vc = NoteDetailViewController()
        _ = vc.view
        vc.display(note)

        let titleField = try XCTUnwrap(firstTitleField(in: vc.view))
        // Titles are stored as slugified filenames, so "OldName" is created as "oldname".
        XCTAssertEqual(titleField.stringValue, "oldname")

        titleField.stringValue = "NewName"
        vc.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: titleField))

        XCTAssertTrue(store.allNotes().contains { $0.title == "newname" })
        XCTAssertFalse(store.allNotes().contains { $0.title == "oldname" })
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
        if let field = view as? NSTextField, field.isBezeled { return field }
        for sub in view.subviews {
            if let field = firstTitleField(in: sub) { return field }
        }
        return nil
    }
}
