import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers the popover row's inline delete confirmation: the first trash click only arms the
/// prompt, and nothing is removed until the checkmark is clicked.
final class NoteRowDeleteTests: XCTestCase {
    private var tempRoot: URL!
    private var note: Note!
    private var row: NoteRowView!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-row-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
        note = try XCTUnwrap(NoteStore.shared.createNote(title: "Doomed", body: "body", category: nil))
        row = NoteRowView(note: note, compact: true, onAction: {})
    }

    override func tearDownWithError() throws {
        row = nil
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    func testFirstClickArmsConfirmationWithoutDeleting() {
        XCTAssertFalse(row.isConfirmingDelete)

        row.confirmDelete()

        XCTAssertTrue(row.isConfirmingDelete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.url.path))
    }

    func testCancelLeavesTheNoteInPlace() {
        row.confirmDelete()
        row.cancelDelete()

        XCTAssertFalse(row.isConfirmingDelete)
        XCTAssertTrue(FileManager.default.fileExists(atPath: note.url.path))
    }

    func testConfirmDeletesTheNoteAndClearsThePrompt() {
        row.confirmDelete()
        row.performDelete()

        XCTAssertFalse(row.isConfirmingDelete)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path))
    }
}
