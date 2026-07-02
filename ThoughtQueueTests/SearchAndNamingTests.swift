import XCTest
@testable import ThoughtQueue

final class SearchAndNamingTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-naming-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    // MARK: - Slug

    func testSlugBasic() {
        XCTAssertEqual(NoteStore.slug("Hello World"), "hello-world")
    }

    func testSlugStripsPunsafeChars() {
        XCTAssertEqual(NoteStore.slug("Meeting: Q3 / plan!"), "meeting-q3-plan")
    }

    func testSlugFirstLineOnly() {
        XCTAssertEqual(NoteStore.slug("Title line\nbody line"), "title-line")
    }

    func testSlugEmptyForBlank() {
        XCTAssertEqual(NoteStore.slug("   "), "")
    }

    // MARK: - Collision naming

    func testUniqueURLAppendsCounterOnCollision() throws {
        let first = store.uniqueURL(stem: "dup", in: tempRoot)
        try "x".write(to: first, atomically: true, encoding: .utf8)
        let second = store.uniqueURL(stem: "dup", in: tempRoot)
        XCTAssertEqual(second.lastPathComponent, "dup-2.md")
    }

    func testCreateNoteNeverOverwrites() throws {
        let a = try XCTUnwrap(store.createNote(title: "same", body: "first", category: nil))
        let b = try XCTUnwrap(store.createNote(title: "same", body: "second", category: nil))
        XCTAssertNotEqual(a.url, b.url)
        XCTAssertEqual(store.body(of: a), "first")
        XCTAssertEqual(store.body(of: b), "second")
    }

    /// uniqueURL must never return a path that already exists, across many collisions (rule #8).
    func testUniqueURLNeverOverwritesAcrossManyCollisions() throws {
        var produced: Set<String> = []
        for _ in 0..<25 {
            let url = store.uniqueURL(stem: "clash", in: tempRoot)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "returned an existing path")
            XCTAssertFalse(produced.contains(url.path), "returned a duplicate path")
            produced.insert(url.path)
            try "x".write(to: url, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(produced.count, 25)
    }

    // MARK: - Category sanitization (rule #1)

    func testSanitizeRejectsParentTraversal() {
        XCTAssertNil(NoteStore.sanitizeCategory(".."))
        XCTAssertNil(NoteStore.sanitizeCategory("../"))
        XCTAssertNil(NoteStore.sanitizeCategory("  ..  "))
    }

    func testSanitizeStripsPathSeparators() {
        XCTAssertEqual(NoteStore.sanitizeCategory("../Evil"), "Evil")
        XCTAssertEqual(NoteStore.sanitizeCategory("a/b"), "a b")
        XCTAssertEqual(NoteStore.sanitizeCategory("a\\b"), "a b")
        XCTAssertEqual(NoteStore.sanitizeCategory("Projects/2026"), "Projects 2026")
    }

    func testSanitizeEmptyAndUncategorizedBecomeNil() {
        XCTAssertNil(NoteStore.sanitizeCategory(""))
        XCTAssertNil(NoteStore.sanitizeCategory("   "))
        XCTAssertNil(NoteStore.sanitizeCategory(nil))
        XCTAssertNil(NoteStore.sanitizeCategory(Note.uncategorized))
    }

    func testSanitizedCategoryStaysInsideRoot() throws {
        // A traversal-laden category must produce a folder under the store root, never above it.
        let note = try XCTUnwrap(store.createNote(title: "trap", body: "x", category: "../../escape"))
        let rootPath = tempRoot.standardizedFileURL.path
        XCTAssertTrue(note.url.standardizedFileURL.path.hasPrefix(rootPath),
                      "note escaped the store root: \(note.url.path)")
    }

    func testCreateCategoryRejectsTraversal() {
        XCTAssertFalse(store.createCategory(".."))
        XCTAssertFalse(store.createCategory("   "))
        // The parent dir of the root must not have gained a stray folder.
        let parent = tempRoot.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.appendingPathComponent("escape").path))
    }

    // MARK: - Fuzzy search

    func testFuzzyScoreMatchesSubsequence() {
        XCTAssertNotNil(FuzzySearch.score(query: "hlo", candidate: "hello"))
        XCTAssertNil(FuzzySearch.score(query: "xyz", candidate: "hello"))
    }

    func testFuzzyEmptyQueryReturnsAll() {
        let notes = makeNotes(["apple", "banana"])
        XCTAssertEqual(FuzzySearch.rank(notes: notes, query: "").count, 2)
    }

    func testFuzzyRanksContiguousAndPrefixHigher() {
        let notes = makeNotes(["meeting-notes", "team-meeting", "miscellaneous"])
        let ranked = FuzzySearch.rank(notes: notes, query: "meet")
        XCTAssertEqual(ranked.first?.title, "meeting-notes")
        XCTAssertFalse(ranked.contains { $0.title == "miscellaneous" })
    }

    private func makeNotes(_ titles: [String]) -> [Note] {
        titles.map { title in
            Note(url: tempRoot.appendingPathComponent("\(title).md"),
                 title: title, category: nil, createdAt: Date(), modifiedAt: Date())
        }
    }
}
