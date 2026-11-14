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

    // MARK: - Sync items

    /// Runs `body` with the stored storage mode set to `mode`, writing UserDefaults directly so no
    /// config notification reaches the live app delegate, then restores the old value.
    private func withStorageMode(_ mode: String?, _ body: () -> Void) {
        let defaults = UserDefaults.standard
        let old = defaults.object(forKey: "storageMode")
        if let mode { defaults.set(mode, forKey: "storageMode") } else { defaults.removeObject(forKey: "storageMode") }
        defer {
            if let old { defaults.set(old, forKey: "storageMode") } else { defaults.removeObject(forKey: "storageMode") }
        }
        body()
    }

    func testSyncItemsAreAbsentInLocalMode() {
        delegate.openConflictsProvider = { [SyncState.Conflict(key: "a.md", detectedAt: Date())] }
        withStorageMode("local") {
            let titles = delegate.buildContextMenu().items.map(\.title)
            XCTAssertFalse(titles.contains("Sync Now"))
            XCTAssertFalse(titles.contains("Resolve Sync Conflicts\u{2026}"))
        }
    }

    func testSyncNowAppearsWhenS3IsEnabledWithoutConflicts() {
        delegate.openConflictsProvider = { [] }
        withStorageMode("both") {
            let titles = delegate.buildContextMenu().items.map(\.title)
            XCTAssertTrue(titles.contains("Sync Now"))
            XCTAssertFalse(titles.contains("Resolve Sync Conflicts\u{2026}"))
        }
    }

    func testResolveConflictsItemAppearsWhenConflictsExist() {
        delegate.openConflictsProvider = { [SyncState.Conflict(key: "a.md", detectedAt: Date())] }
        withStorageMode("s3") {
            let item = delegate.buildContextMenu().items.first { $0.title == "Resolve Sync Conflicts\u{2026}" }
            XCTAssertEqual(item?.action, #selector(AppDelegate.openSyncConflicts))
        }
    }
}
