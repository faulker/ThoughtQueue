import XCTest
@testable import ThoughtQueue

/// Covers resolving the working-document preference to a note, and the menu bar
/// double-click action that opens it.
@MainActor
final class WorkingDocumentTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!
    private var savedWorkingDoc: URL!

    override func setUpWithError() throws {
        closeNoteWindows() // isolate from any windows a prior case left behind
        savedWorkingDoc = PreferencesManager.shared.workingDocumentURL
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-workingdoc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        closeNoteWindows()
        PreferencesManager.shared.workingDocumentURL = savedWorkingDoc
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    private func closeNoteWindows() {
        noteWindows().forEach { $0.close() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func noteWindows() -> [NSWindow] {
        NSApp.windows.filter { $0.noteEditor != nil }
    }

    // MARK: - NoteStore.workingDocumentNote

    func testWorkingDocumentNoteIsNilWhenUnset() {
        PreferencesManager.shared.workingDocumentURL = nil

        XCTAssertNil(store.workingDocumentNote)
    }

    func testWorkingDocumentNoteResolvesSetNote() throws {
        let note = try XCTUnwrap(store.createNote(title: "Daily Log", body: "hi", category: "Work"))
        PreferencesManager.shared.workingDocumentURL = note.url

        let resolved = try XCTUnwrap(store.workingDocumentNote)
        XCTAssertEqual(resolved.url.standardizedFileURL, note.url.standardizedFileURL)
        XCTAssertEqual(resolved.title, note.title)
        XCTAssertEqual(resolved.category, "Work")
    }

    func testWorkingDocumentNoteIsNilWhenFileDeletedExternally() throws {
        let note = try XCTUnwrap(store.createNote(title: "Doomed", body: "hi", category: nil))
        PreferencesManager.shared.workingDocumentURL = note.url
        try FileManager.default.removeItem(at: note.url)

        XCTAssertNil(store.workingDocumentNote, "a stale path must not resolve to a note")
    }

    // MARK: - Menu bar click routing

    func testDoubleLeftClickOpensWorkingDocument() {
        XCTAssertEqual(AppDelegate.statusItemAction(eventType: .leftMouseUp, clickCount: 2), .workingDocument)
    }

    func testSingleLeftClickTogglesPopover() {
        XCTAssertEqual(AppDelegate.statusItemAction(eventType: .leftMouseUp, clickCount: 1), .popover)
    }

    /// A triple click still lands on the working document rather than falling back to the popover.
    func testTripleLeftClickOpensWorkingDocument() {
        XCTAssertEqual(AppDelegate.statusItemAction(eventType: .leftMouseUp, clickCount: 3), .workingDocument)
    }

    func testRightClickOpensContextMenuRegardlessOfClickCount() {
        XCTAssertEqual(AppDelegate.statusItemAction(eventType: .rightMouseUp, clickCount: 1), .contextMenu)
        XCTAssertEqual(AppDelegate.statusItemAction(eventType: .rightMouseUp, clickCount: 2), .contextMenu)
    }

    // MARK: - AppDelegate.openWorkingDocument

    func testOpenWorkingDocumentOpensItsWindow() throws {
        let note = try XCTUnwrap(store.createNote(title: "Open Me", body: "body", category: nil))
        PreferencesManager.shared.workingDocumentURL = note.url

        AppDelegate().openWorkingDocument()

        XCTAssertTrue(noteWindows().contains { $0.title == note.title },
                      "double-click should open the working document's window")
    }

    func testOpenWorkingDocumentOpensNothingWhenUnset() {
        PreferencesManager.shared.workingDocumentURL = nil
        let before = noteWindows().count

        AppDelegate().openWorkingDocument()

        XCTAssertEqual(noteWindows().count, before, "no working document means no new window")
    }

    func testOpenWorkingDocumentClearsStalePreference() throws {
        let note = try XCTUnwrap(store.createNote(title: "Gone", body: "body", category: nil))
        PreferencesManager.shared.workingDocumentURL = note.url
        try FileManager.default.removeItem(at: note.url)
        let before = noteWindows().count

        AppDelegate().openWorkingDocument()

        XCTAssertNil(PreferencesManager.shared.workingDocumentURL,
                     "a missing working document should clear the setting")
        XCTAssertEqual(noteWindows().count, before, "a missing note must not open a window")
    }
}
