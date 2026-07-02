import XCTest
@testable import ThoughtQueue

final class NoteStoreTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    func testCreateNoteInUncategorized() throws {
        let note = store.createNote(title: "Hello World", body: "some body", category: nil)
        let unwrapped = try XCTUnwrap(note)
        XCTAssertEqual(unwrapped.title, "hello-world")
        XCTAssertNil(unwrapped.category)
        XCTAssertEqual(store.body(of: unwrapped), "some body")
        XCTAssertTrue(FileManager.default.fileExists(atPath: unwrapped.url.path))
    }

    func testCreateNoteInCategoryCreatesFolder() throws {
        let note = try XCTUnwrap(store.createNote(title: "Task", body: "x", category: "Work"))
        XCTAssertEqual(note.category, "Work")
        let folder = tempRoot.appendingPathComponent("Work", isDirectory: true)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testTitleFallsBackToFirstBodyLine() throws {
        let note = try XCTUnwrap(store.createNote(title: "", body: "First line here\nsecond", category: nil))
        XCTAssertEqual(note.title, "first-line-here")
    }

    func testTitleFallsBackToTimestampWhenBodyEmpty() throws {
        let note = try XCTUnwrap(store.createNote(title: "", body: "", category: nil))
        XCTAssertTrue(note.title.hasPrefix("note-"))
    }

    func testAppend() throws {
        let note = try XCTUnwrap(store.createNote(title: "Log", body: "line1", category: nil))
        XCTAssertTrue(store.append(to: note, text: "line2"))
        XCTAssertEqual(store.body(of: note), "line1\n\nline2")
    }

    func testAppendToMissingFails() throws {
        let note = try XCTUnwrap(store.createNote(title: "Temp", body: "x", category: nil))
        try FileManager.default.removeItem(at: note.url)
        XCTAssertFalse(store.append(to: note, text: "y"))
    }

    func testUpdateBody() throws {
        let note = try XCTUnwrap(store.createNote(title: "Doc", body: "old", category: nil))
        XCTAssertTrue(store.updateBody(of: note, body: "new"))
        XCTAssertEqual(store.body(of: note), "new")
    }

    func testRename() throws {
        let note = try XCTUnwrap(store.createNote(title: "Before", body: "x", category: nil))
        let renamed = try XCTUnwrap(store.rename(note, to: "After Name"))
        XCTAssertEqual(renamed.title, "after-name")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path))
        XCTAssertEqual(store.body(of: renamed), "x")
    }

    func testMoveBetweenCategories() throws {
        let note = try XCTUnwrap(store.createNote(title: "Movable", body: "x", category: nil))
        let moved = try XCTUnwrap(store.move(note, to: "Archive"))
        XCTAssertEqual(moved.category, "Archive")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path))
    }

    func testDelete() throws {
        let note = try XCTUnwrap(store.createNote(title: "Doomed", body: "x", category: nil))
        XCTAssertTrue(store.delete(note))
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.url.path))
    }

    func testCreateEmptyCategoryIsListed() throws {
        XCTAssertTrue(store.createCategory("Inbox"))
        // An empty category folder (no notes yet) must still appear in the listing.
        XCTAssertTrue(store.categories().contains("Inbox"))
        XCTAssertTrue(store.notes(in: "Inbox").isEmpty)
    }

    func testCategoriesListing() throws {
        _ = store.createNote(title: "A", body: "x", category: "Alpha")
        _ = store.createNote(title: "B", body: "x", category: "Beta")
        let cats = store.categories()
        XCTAssertEqual(cats, ["Alpha", "Beta"])
    }

    func testNotesInCategoryFilter() throws {
        _ = store.createNote(title: "RootNote", body: "x", category: nil)
        _ = store.createNote(title: "WorkNote", body: "x", category: "Work")
        XCTAssertEqual(store.notes(in: nil).count, 1)
        XCTAssertEqual(store.notes(in: "Work").count, 1)
        XCTAssertEqual(store.allNotes().count, 2)
    }

    func testCategoryDerivedFromNestedPath() throws {
        // A note placed directly in a subfolder gets that folder as its category.
        let work = tempRoot.appendingPathComponent("Projects", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let url = work.appendingPathComponent("note.md")
        try "hi".write(to: url, atomically: true, encoding: .utf8)
        let note = try XCTUnwrap(Note.from(url: url, storeRoot: tempRoot))
        XCTAssertEqual(note.category, "Projects")
    }
}
