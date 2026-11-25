import XCTest
@testable import ThoughtQueue

/// Tests for capture guards: whitespace no-op and working-document external-delete fallback.
final class CaptureServiceTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-capture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
        savedWorkingDocument = PreferencesManager.shared.workingDocumentURL
        // Ensure a clean working-doc setting for each test.
        PreferencesManager.shared.workingDocumentURL = nil
        // Keep capture tests deterministic: no background model calls.
        autoIntelWasEnabled = PreferencesManager.shared.autoIntelEnabled
        PreferencesManager.shared.autoIntelEnabled = false
    }

    private var autoIntelWasEnabled = true
    /// The tests run in the real app, so the user's own setting must be put back.
    private var savedWorkingDocument: URL?

    override func tearDownWithError() throws {
        PreferencesManager.shared.autoIntelEnabled = autoIntelWasEnabled
        PreferencesManager.shared.workingDocumentURL = savedWorkingDocument
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    // MARK: - Whitespace-only capture (rule #4)

    func testWhitespaceOnlyCaptureIsNoOp() {
        let before = store.allNotes().count
        let result = CaptureService.shared.persistCapture(text: "   \n\t  ")
        XCTAssertEqual(result, .empty)
        XCTAssertEqual(store.allNotes().count, before, "whitespace capture must not create a note")
    }

    func testEmptyStringCaptureIsNoOp() {
        let result = CaptureService.shared.persistCapture(text: "")
        XCTAssertEqual(result, .empty)
        XCTAssertEqual(store.allNotes().count, 0)
    }

    func testRealCaptureCreatesNote() {
        let result = CaptureService.shared.persistCapture(text: "real content")
        XCTAssertEqual(result, .created)
        XCTAssertEqual(store.allNotes().count, 1)
    }

    // MARK: - Working-document external delete fallback (rule #6)

    func testCaptureAppendsToWorkingDocument() throws {
        let working = try XCTUnwrap(store.createNote(title: "working", body: "start", category: nil))
        PreferencesManager.shared.workingDocumentURL = working.url

        let result = CaptureService.shared.persistCapture(text: "appended line")
        XCTAssertEqual(result, .appended("working"))
        XCTAssertEqual(store.body(of: working), "start\n\nappended line")
        XCTAssertEqual(store.allNotes().count, 1, "append should not create a second note")
    }

    func testFailedAppendKeepsTheSetting() throws {
        // A folder at the path exists but cannot be written as a file.
        let blocked = tempRoot.appendingPathComponent("blocked.md", isDirectory: true)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        PreferencesManager.shared.workingDocumentURL = blocked

        XCTAssertEqual(CaptureService.shared.persistCapture(text: "text"), .created)
        XCTAssertEqual(PreferencesManager.shared.workingDocumentURL?.path, blocked.path)
    }

    func testRenameMoveAndDeleteFollowTheWorkingDocument() throws {
        let note = try XCTUnwrap(store.createNote(title: "sink", body: "x", category: nil))
        PreferencesManager.shared.workingDocumentURL = note.url

        let renamed = try XCTUnwrap(store.rename(note, to: "renamed"))
        XCTAssertEqual(store.workingDocumentNote?.title, "renamed")
        let moved = try XCTUnwrap(store.move(renamed, to: "Work"))
        XCTAssertEqual(store.workingDocumentNote?.category, "Work")
        XCTAssertTrue(store.delete(moved))
        XCTAssertNil(PreferencesManager.shared.workingDocumentURL)
    }

    func testDeletingAnotherNoteKeepsTheWorkingDocument() throws {
        let note = try XCTUnwrap(store.createNote(title: "sink", body: "x", category: nil))
        let other = try XCTUnwrap(store.createNote(title: "other", body: "x", category: nil))
        PreferencesManager.shared.workingDocumentURL = note.url
        XCTAssertTrue(store.delete(other))
        XCTAssertEqual(store.workingDocumentNote?.title, "sink")
    }

    func testWorkingDocDeletedExternallyFallsBackToNewNoteAndKeepsSetting() throws {
        let working = try XCTUnwrap(store.createNote(title: "working", body: "start", category: nil))
        PreferencesManager.shared.workingDocumentURL = working.url

        // Simulate external deletion.
        try FileManager.default.removeItem(at: working.url)

        let result = CaptureService.shared.persistCapture(text: "orphan capture")
        XCTAssertEqual(result, .created, "should create a new note when the working doc is gone")
        XCTAssertEqual(PreferencesManager.shared.workingDocumentURL?.path, working.url.path,
                       "a missing file must not unset the working document")

        // A fresh note exists with the captured content.
        let notes = store.allNotes()
        XCTAssertEqual(notes.count, 1)
        XCTAssertEqual(store.body(of: notes[0]), "orphan capture")
    }
}
