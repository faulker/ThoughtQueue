import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers the explicit document-type metadata: that it is recorded, that it beats content
/// inference, that it follows a note through renames, moves and category edits, and that a
/// store with no metadata file still behaves exactly as it did before.
final class NoteMetadataTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    // MARK: - Pure helpers

    func testKeyIsStoreRelative() {
        let root = URL(fileURLWithPath: "/tmp/store")
        XCTAssertEqual(NoteMetadataStore.key(for: root.appendingPathComponent("a.md"), root: root), "a.md")
        XCTAssertEqual(NoteMetadataStore.key(for: root.appendingPathComponent("Work/a.md"), root: root),
                       "Work/a.md")
    }

    func testKeyRejectsPathsOutsideTheRoot() {
        let root = URL(fileURLWithPath: "/tmp/store")
        XCTAssertNil(NoteMetadataStore.key(for: URL(fileURLWithPath: "/tmp/other/a.md"), root: root))
        XCTAssertNil(NoteMetadataStore.key(for: root, root: root))
    }

    func testResolveReturnsTheRecordedType() {
        XCTAssertEqual(NoteMetadataStore.resolve(explicit: .markdown), .markdown)
        XCTAssertEqual(NoteMetadataStore.resolve(explicit: .checklist), .checklist)
    }

    /// Content is never consulted: a note is a list because it was declared one.
    func testResolveDefaultsToMarkdownWhenNothingIsRecorded() {
        XCTAssertEqual(NoteMetadataStore.resolve(explicit: nil), .markdown)
    }

    // MARK: - Recording

    func testCreateNoteRecordsTheRequestedType() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "", category: nil,
                                                             docType: .markdown))
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: note.url), .markdown)
        XCTAssertEqual(NoteStore.shared.docType(of: note), .markdown)
    }

    /// The reported bug: a scratch note that happens to be nothing but task lines is not a
    /// checklist, and no reading of its bytes can say otherwise.
    func testANoteWithNoRecordedTypeIsAMarkdownDocument() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "- [ ] a\n", category: nil))
        XCTAssertNil(NoteMetadataStore.shared.docType(for: note.url))
        XCTAssertEqual(NoteStore.shared.docType(of: note), .markdown)
    }

    /// The bug this metadata exists for: typing a checkbox as the first line of a prose note
    /// used to turn it into a checklist on the next open.
    func testACheckboxTypedIntoAMarkdownNoteDoesNotConvertIt() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Notes", body: "", category: nil,
                                                             docType: .markdown))
        XCTAssertTrue(NoteStore.shared.updateBody(of: note, body: "- [ ] milk\n"))
        XCTAssertEqual(NoteStore.shared.docType(of: note), .markdown)
    }

    func testSettingTheTypeToNilFallsBackToMarkdown() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "- [ ] a\n",
                                                             category: nil, docType: .checklist))
        NoteStore.shared.setDocType(nil, of: note)
        XCTAssertNil(NoteMetadataStore.shared.docType(for: note.url))
        XCTAssertEqual(NoteStore.shared.docType(of: note), .markdown)
    }

    // MARK: - Persistence

    func testTheTypeIsWrittenToAHiddenSidecarNotTheNote() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "body", category: nil,
                                                             docType: .checklist))
        let sidecar = tempRoot
            .appendingPathComponent(NoteMetadataStore.folderName, isDirectory: true)
            .appendingPathComponent(NoteMetadataStore.fileName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        XCTAssertEqual(try String(contentsOf: note.url, encoding: .utf8), "body",
                       "the note's own bytes must be untouched")
    }

    func testTheSidecarSurvivesAReload() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "x", category: nil,
                                                             docType: .checklist))
        NoteMetadataStore.shared.invalidateCache()
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: note.url), .checklist)
    }

    /// The sidecar lives in a hidden folder, so it can never be mistaken for a category.
    func testTheSidecarFolderIsNotACategory() throws {
        _ = NoteStore.shared.createNote(title: "A", body: "x", category: nil, docType: .checklist)
        XCTAssertFalse(NoteStore.shared.categories().contains(NoteMetadataStore.folderName))
    }

    // MARK: - Following the file

    func testRenameCarriesTheType() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Before", body: "x", category: nil,
                                                             docType: .checklist))
        let renamed = try XCTUnwrap(NoteStore.shared.rename(note, to: "After"))
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: renamed.url), .checklist)
        XCTAssertNil(NoteMetadataStore.shared.docType(for: note.url))
    }

    func testMoveCarriesTheType() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "x", category: nil,
                                                             docType: .markdown))
        let moved = try XCTUnwrap(NoteStore.shared.move(note, to: "Work"))
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: moved.url), .markdown)
    }

    func testDeleteForgetsTheType() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "x", category: nil,
                                                             docType: .checklist))
        XCTAssertTrue(NoteStore.shared.delete(note))
        XCTAssertNil(NoteMetadataStore.shared.docType(for: note.url))
    }

    func testCloneCarriesTheType() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "- [ ] a\n",
                                                             category: nil, docType: .markdown))
        let copy = try XCTUnwrap(NoteStore.shared.clone(note))
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: copy.url), .markdown)
    }

    func testRenamingACategoryReKeysItsNotes() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "x", category: "Old",
                                                             docType: .checklist))
        XCTAssertTrue(NoteStore.shared.renameCategory("Old", to: "New"))
        let moved = tempRoot.appendingPathComponent("New/\(note.url.lastPathComponent)")
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: moved), .checklist)
    }

    func testDeletingACategoryKeepsTheTypeWithTheRelocatedNote() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "A", body: "x", category: "Temp",
                                                             docType: .checklist))
        XCTAssertTrue(NoteStore.shared.deleteCategory("Temp"))
        let relocated = tempRoot.appendingPathComponent(note.url.lastPathComponent)
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: relocated), .checklist)
    }
}
