import XCTest
@testable import ThoughtQueue

/// Conflict descriptions, and where per-device sync state lives.
final class ConflictDetailsTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("tq-details-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    func testTitlesAndCategories() {
        XCTAssertEqual(ConflictDetails.title(forKey: "Work/My plan.md"), "My plan")
        XCTAssertEqual(ConflictDetails.category(forKey: "Work/My plan.md"), "Work")
        XCTAssertEqual(ConflictDetails.category(forKey: "a.md"), Note.uncategorized)
        XCTAssertEqual(ConflictDetails.title(forKey: SyncEngine.settingsKey), "App settings")
        XCTAssertNil(ConflictDetails.category(forKey: SyncEngine.metadataKey))
    }

    func testNewerSide() throws {
        let file = root.appendingPathComponent("a.md")
        try Data("x".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: file.path)
        func newer(_ remote: Date?) throws -> ConflictDetails.Side? {
            try ConflictDetails.load(.init(key: "a.md", detectedAt: Date(), remoteModifiedAt: remote), root: root).newer
        }
        XCTAssertEqual(try newer(Date(timeIntervalSince1970: 2_000)), .remote)
        XCTAssertEqual(try newer(Date(timeIntervalSince1970: 500)), .local)
        XCTAssertNil(try newer(nil))
    }

    func testSideDescription() {
        XCTAssertEqual(ConflictDetails.sideDescription(verb: "edited", date: Date(), text: nil), "deleted")
        XCTAssertTrue(ConflictDetails.sideDescription(verb: "uploaded", date: nil, text: "x").hasPrefix("date unknown"))
        XCTAssertTrue(ConflictDetails.sideDescription(verb: "edited", date: Date(), text: "x").hasPrefix("edited "))
    }

    func testChangedLines() {
        let changed = ConflictDetails.changedLines(local: "a\nb\nc", remote: "a\nB\nc\nd")
        XCTAssertEqual(changed.local, [1])
        XCTAssertEqual(changed.remote, [1, 3])
    }

    // MARK: - State location

    func testStateLivesOutsideTheNotesFolderAndDiffersPerRoot() {
        XCTAssertFalse(SyncState.fileURL(root: root).path.hasPrefix(root.path + "/"))
        XCTAssertNotEqual(SyncState.directory(root: root), SyncState.directory(root: root.appendingPathComponent("x")))
    }

    /// Writes an old in-folder state file with one parked copy.
    private func writeLegacyState() throws -> URL {
        let folder = root.appendingPathComponent(".thoughtqueue")
        try fm.createDirectory(at: folder.appendingPathComponent("conflicts"), withIntermediateDirectories: true)
        let json = #"{"configIdentity":"id","conflicts":[{"key":"a.md","detectedAt":"2026-11-13T10:00:00Z"}],"entries":{}}"#
        try Data(json.utf8).write(to: folder.appendingPathComponent("sync-state.json"))
        try Data("parked".utf8).write(to: folder.appendingPathComponent("conflicts/a.md"))
        return folder.appendingPathComponent("sync-state.json")
    }

    func testCacheStateMigratesWithParkedCopiesAndOldConflictsDecode() throws {
        let legacy = try writeLegacyState()
        try SyncState.migrateLegacy(root: root, cacheURL: root)
        XCTAssertFalse(fm.fileExists(atPath: legacy.path))
        let conflict = try XCTUnwrap(SyncState.load(root: root, identity: "id").conflicts.first)
        XCTAssertEqual(conflict.key, "a.md")
        XCTAssertNil(conflict.remoteModifiedAt)
        XCTAssertEqual(try String(contentsOf: SyncState.conflictFileURL(key: "a.md", root: root), encoding: .utf8), "parked")
    }

    func testChosenFolderStartsFreshAndKeepsTheOldFile() throws {
        let legacy = try writeLegacyState()
        XCTAssertTrue(try SyncState.load(root: root, identity: "id").conflicts.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: legacy.path))
    }
}
