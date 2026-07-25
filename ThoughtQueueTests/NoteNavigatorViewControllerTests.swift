import XCTest
@testable import ThoughtQueue

/// Verifies the note window's navigation panel: how it groups notes, how search filters the
/// tree, and that programmatic highlighting never looks like a user selection.
@MainActor
final class NoteNavigatorViewControllerTests: XCTestCase {
    var tempRoot: URL!
    var store: NoteStore!
    private var savedWorkingDoc: URL?

    override func setUpWithError() throws {
        savedWorkingDoc = PreferencesManager.shared.workingDocumentURL
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-nav-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        store = NoteStore.shared
        store.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        PreferencesManager.shared.workingDocumentURL = savedWorkingDoc
        try? FileManager.default.removeItem(at: tempRoot)
        store.rootURL = nil
    }

    /// A loaded navigator plus its outline view.
    private func makeNavigator() throws -> (NoteNavigatorViewController, NSOutlineView) {
        let navigator = NoteNavigatorViewController()
        navigator.reload()
        let outline = try XCTUnwrap(firstView(NSOutlineView.self, in: navigator.view))
        return (navigator, outline)
    }

    /// Every group row in display order.
    private func groupNames(in outline: NSOutlineView) -> [String] {
        (0..<outline.numberOfRows).compactMap { row in
            guard let node = outline.item(atRow: row) as? NoteNavigatorNode, node.isGroup else { return nil }
            return node.category
        }
    }

    /// Note titles under a given group, in display order.
    private func noteTitles(inGroup name: String, of outline: NSOutlineView) -> [String] {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? NoteNavigatorNode,
                  node.isGroup, node.category == name else { continue }
            return node.children.compactMap { $0.note?.title }
        }
        return []
    }

    func testNavigatorGroupsNotesByCategoryWithUncategorizedLast() throws {
        _ = store.createNote(title: "Work Thing", body: "x", category: "Work")
        _ = store.createNote(title: "Loose Thing", body: "x", category: nil)
        _ = store.createCategory("Empty")

        let (_, outline) = try makeNavigator()

        XCTAssertEqual(groupNames(in: outline), ["Work", Note.uncategorized],
                       "categories come first, Uncategorized last, and empty categories are dropped")
    }

    func testNavigatorOrdersNotesNewestFirstWithinGroup() throws {
        let older = try XCTUnwrap(store.createNote(title: "Older", body: "x", category: "Work"))
        let newer = try XCTUnwrap(store.createNote(title: "Newer", body: "x", category: "Work"))
        // Make the ordering unambiguous regardless of how fast the two files were written.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-600)],
                                             ofItemAtPath: older.url.path)
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: newer.url.path)

        let (_, outline) = try makeNavigator()

        XCTAssertEqual(noteTitles(inGroup: "Work", of: outline), [newer.title, older.title],
                       "most recently modified note should come first")
    }

    func testSearchFiltersToMatchingNotes() throws {
        _ = store.createNote(title: "Alpha Report", body: "x", category: "Work")
        _ = store.createNote(title: "Zebra Notes", body: "x", category: "Work")

        let (navigator, outline) = try makeNavigator()
        let searchField = try XCTUnwrap(firstView(NSSearchField.self, in: navigator.view))
        searchField.stringValue = "zeb"
        navigator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        XCTAssertEqual(noteTitles(inGroup: "Work", of: outline), ["zebra-notes"],
                       "only fuzzy-matching notes should remain")

        searchField.stringValue = ""
        navigator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))
        XCTAssertEqual(noteTitles(inGroup: "Work", of: outline).count, 2, "clearing the query restores the tree")
    }

    func testSearchDropsGroupsWithoutMatches() throws {
        _ = store.createNote(title: "Alpha Report", body: "x", category: "Work")
        _ = store.createNote(title: "Grocery List", body: "x", category: "Home")

        let (navigator, outline) = try makeNavigator()
        let searchField = try XCTUnwrap(firstView(NSSearchField.self, in: navigator.view))
        searchField.stringValue = "grocery"
        navigator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: searchField))

        XCTAssertEqual(groupNames(in: outline), ["Home"], "groups with no matches should disappear while searching")
    }

    func testHighlightSelectsRowWithoutFiringCallback() throws {
        _ = store.createNote(title: "First", body: "x", category: "Work")
        let target = try XCTUnwrap(store.createNote(title: "Target", body: "x", category: "Work"))

        let (navigator, outline) = try makeNavigator()
        var callbacks = 0
        navigator.onNoteSelected = { _ in callbacks += 1 }

        navigator.highlight(note: target)

        let selected = outline.item(atRow: outline.selectedRow) as? NoteNavigatorNode
        XCTAssertEqual(selected?.note?.url.standardizedFileURL, target.url.standardizedFileURL,
                       "the target note's row should be selected")
        XCTAssertEqual(navigator.highlightedURL, target.url.standardizedFileURL)
        XCTAssertEqual(callbacks, 0, "programmatic highlighting must not look like a user selection")
    }

    func testHighlightSurvivesReloadThatResorts() throws {
        let first = try XCTUnwrap(store.createNote(title: "Stays Selected", body: "x", category: "Work"))
        let second = try XCTUnwrap(store.createNote(title: "Bumped Later", body: "x", category: "Work"))

        let (navigator, outline) = try makeNavigator()
        navigator.highlight(note: first)

        // Touch the other note so a reload re-sorts the group and row indexes shift.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                             ofItemAtPath: second.url.path)
        navigator.reload()

        let selected = outline.item(atRow: outline.selectedRow) as? NoteNavigatorNode
        XCTAssertEqual(selected?.note?.url.standardizedFileURL, first.url.standardizedFileURL,
                       "selection follows the note, not the row index")
    }

    func testWorkingDocumentRowShowsBadge() throws {
        let plain = try XCTUnwrap(store.createNote(title: "Plain", body: "x", category: "Work"))
        let working = try XCTUnwrap(store.createNote(title: "Working", body: "x", category: "Work"))
        PreferencesManager.shared.workingDocumentURL = working.url

        let (navigator, outline) = try makeNavigator()

        XCTAssertTrue(hasBadge(for: working, navigator: navigator, outline: outline),
                      "the working document row should carry a badge")
        XCTAssertFalse(hasBadge(for: plain, navigator: navigator, outline: outline),
                       "ordinary rows should have no badge")
    }

    /// Whether the row view built for `note` contains an image view (the working-doc badge).
    private func hasBadge(for note: Note, navigator: NoteNavigatorViewController, outline: NSOutlineView) -> Bool {
        for row in 0..<outline.numberOfRows {
            guard let node = outline.item(atRow: row) as? NoteNavigatorNode,
                  node.note?.url.standardizedFileURL == note.url.standardizedFileURL,
                  let view = navigator.outlineView(outline, viewFor: outline.tableColumns.first, item: node)
            else { continue }
            return firstView(NSImageView.self, in: view) != nil
        }
        return false
    }

    /// Recursively locate the first view of a given type in a hierarchy.
    private func firstView<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for sub in view.subviews {
            if let match = firstView(type, in: sub) { return match }
        }
        return nil
    }
}
