import XCTest
@testable import ThoughtQueue

/// Loading both sides of a conflict for the resolution window.
final class SyncConflictWindowTests: XCTestCase {
    private var root: URL!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("tq-conflict-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? fm.removeItem(at: root)
    }

    private func write(_ url: URL, _ text: String) throws {
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    func testLoadsLocalAndParkedRemoteText() throws {
        try write(root.appendingPathComponent("Work/a.md"), "local")
        try write(SyncState.conflictFileURL(key: "Work/a.md", root: root), "remote")
        let sides = try ConflictSides.load(key: "Work/a.md", root: root)
        XCTAssertEqual(sides, ConflictSides(local: "local", remote: "remote"))
    }

    func testMissingLocalIsNilMeaningDeleted() throws {
        try write(SyncState.conflictFileURL(key: "a.md", root: root), "remote")
        let sides = try ConflictSides.load(key: "a.md", root: root)
        XCTAssertNil(sides.local)
        XCTAssertEqual(sides.remote, "remote")
    }

    func testMissingRemoteIsNilMeaningDeleted() throws {
        try write(root.appendingPathComponent("a.md"), "local")
        let sides = try ConflictSides.load(key: "a.md", root: root)
        XCTAssertEqual(sides.local, "local")
        XCTAssertNil(sides.remote)
    }

    func testRejectsKeysOutsideTheSyncedSet() {
        XCTAssertThrowsError(try ConflictSides.load(key: "../evil.md", root: root))
    }
}
