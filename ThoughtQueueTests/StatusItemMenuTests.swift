import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers the menu bar icon's right-click menu, including the "Open Notes Folder" entry that
/// reveals the store directory.
final class StatusItemMenuTests: XCTestCase {
    private var delegate: AppDelegate!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        delegate = AppDelegate()
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    func testContextMenuOffersOpeningTheNotesFolder() {
        NoteStore.shared.rootURL = tempRoot
        let item = delegate.buildContextMenu().items.first { $0.title == "Open Notes Folder" }
        XCTAssertNotNil(item)
        XCTAssertEqual(item?.action, #selector(AppDelegate.openStoreFolder))
        XCTAssertTrue(item?.isEnabled ?? false)
    }

    func testOpenNotesFolderIsDisabledBeforeAStoreIsChosen() {
        NoteStore.shared.rootURL = nil
        let item = delegate.buildContextMenu().items.first { $0.title == "Open Notes Folder" }
        XCTAssertEqual(item?.isEnabled, false)
    }

    func testContextMenuKeepsItsExistingEntries() {
        NoteStore.shared.rootURL = tempRoot
        let titles = delegate.buildContextMenu().items.map(\.title)
        XCTAssertTrue(titles.contains("Categories\u{2026}"))
        XCTAssertTrue(titles.contains("Preferences\u{2026}"))
        XCTAssertTrue(titles.contains("Quit"))
    }
}
