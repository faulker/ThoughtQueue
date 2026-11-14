import XCTest
@testable import ThoughtQueue

/// End-to-end sync tests: a temp store root against `InMemoryObjectStore`, no network,
/// no UserDefaults, no Keychain.
@MainActor
final class SyncEngineTests: XCTestCase {
    private var tempRoot: URL!
    private var remote: InMemoryObjectStore!
    private var engine: SyncEngine!
    private var context: SyncContext!
    private let fm = FileManager.default

    override func setUp() async throws {
        tempRoot = fm.temporaryDirectory.appendingPathComponent("tq-sync-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
        remote = InMemoryObjectStore()
        engine = SyncEngine()
        context = SyncContext(store: remote, root: tempRoot, identity: "http://s3.test|bucket|")
    }

    override func tearDown() async throws {
        try? fm.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    // MARK: - Helpers

    /// Writes a local file under the root, creating folders.
    private func writeLocal(_ key: String, _ text: String, root: URL? = nil) throws {
        let url = (root ?? tempRoot).appendingPathComponent(key)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Reads a local file under the root, or nil when missing.
    private func readLocal(_ key: String) -> String? {
        let url = tempRoot.appendingPathComponent(key)
        guard let data = fm.contents(atPath: url.path) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Reads a remote object, or nil when missing.
    private func readRemote(_ key: String) async throws -> String? {
        guard let content = try await SyncEngine.getIfExists(key: key, store: remote) else { return nil }
        return String(decoding: content.data, as: UTF8.self)
    }

    private func putRemote(_ key: String, _ text: String) async throws {
        _ = try await remote.put(key: key, data: Data(text.utf8))
    }

    private func state() throws -> SyncState {
        try SyncState.load(root: tempRoot, identity: context.identity)
    }

    /// Syncs "note.md" to both sides, then edits it on both, and runs the sync that records the conflict.
    private func makeConflict(local: String = "local edit", remoteText: String = "remote edit") async throws {
        try writeLocal("note.md", "base")
        try await engine.run(context: context)
        try writeLocal("note.md", local)
        try await putRemote("note.md", remoteText)
        try await engine.run(context: context)
        XCTAssertTrue(try state().hasConflict("note.md"))
    }

    // MARK: - Propagation

    func testUploadRoundTrip() async throws {
        try writeLocal("hello.md", "hi")
        try writeLocal("Work/plan.md", "plan")

        let first = try await engine.run(context: context)
        XCTAssertEqual(Set(first.uploaded), ["hello.md", "Work/plan.md"])
        let remoteHello = try await readRemote("hello.md")
        let remotePlan = try await readRemote("Work/plan.md")
        XCTAssertEqual(remoteHello, "hi")
        XCTAssertEqual(remotePlan, "plan")

        let second = try await engine.run(context: context)
        XCTAssertEqual(second, SyncReport(), "an unchanged store syncs to nothing")

        try writeLocal("hello.md", "hi again")
        let third = try await engine.run(context: context)
        XCTAssertEqual(third.uploaded, ["hello.md"])
        let updated = try await readRemote("hello.md")
        XCTAssertEqual(updated, "hi again")
    }

    func testDownloadNewNoteInNewCategory() async throws {
        try await putRemote("Ideas/new.md", "from elsewhere")
        let changed = expectation(forNotification: .notesDidChange, object: nil)

        let report = try await engine.run(context: context)

        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(report.downloaded, ["Ideas/new.md"])
        XCTAssertEqual(readLocal("Ideas/new.md"), "from elsewhere")
        XCTAssertTrue(NoteStore.shared.categories().contains("Ideas"))
        XCTAssertTrue(NoteStore.shared.allNotes().contains { $0.title == "new" && $0.category == "Ideas" })
    }

    func testRemoteEditDownloads() async throws {
        try writeLocal("a.md", "v1")
        try await engine.run(context: context)
        try await putRemote("a.md", "v2")

        let report = try await engine.run(context: context)
        XCTAssertEqual(report.downloaded, ["a.md"])
        XCTAssertEqual(readLocal("a.md"), "v2")
    }

    func testLocalDeletePropagatesToRemote() async throws {
        try writeLocal("gone.md", "x")
        try await engine.run(context: context)
        try fm.removeItem(at: tempRoot.appendingPathComponent("gone.md"))

        let report = try await engine.run(context: context)
        XCTAssertEqual(report.deletedRemote, ["gone.md"])
        let remoteGone = try await readRemote("gone.md")
        XCTAssertNil(remoteGone)
        XCTAssertNil(try state().entries["gone.md"])
    }

    func testRemoteDeletePropagatesToLocal() async throws {
        try writeLocal("Work/gone.md", "x")
        try await engine.run(context: context)
        try await remote.delete(key: "Work/gone.md")

        let report = try await engine.run(context: context)
        XCTAssertEqual(report.deletedLocal, ["Work/gone.md"])
        XCTAssertNil(readLocal("Work/gone.md"))
    }

    func testDownloadedMetadataInvalidatesCache() async throws {
        try fm.createDirectory(at: tempRoot.appendingPathComponent("Work"), withIntermediateDirectories: true)
        XCTAssertFalse(NoteStore.shared.isArchived(category: "Work"), "primes the metadata cache")
        try await putRemote(SyncEngine.metadataKey, #"{"version":1,"notes":{},"folders":{"Work":{"archived":true}}}"#)

        let report = try await engine.run(context: context)
        XCTAssertEqual(report.downloaded, [SyncEngine.metadataKey])
        XCTAssertTrue(NoteStore.shared.isArchived(category: "Work"))
    }

    // MARK: - Conflicts

    func testConflictCreation() async throws {
        let detected = expectation(forNotification: .syncConflictsDetected, object: nil) { note in
            (note.userInfo?["keys"] as? [String]) == ["note.md"]
        }
        try await makeConflict()
        await fulfillment(of: [detected], timeout: 2)

        // Both sides untouched, the remote copy parked, the conflict recorded.
        XCTAssertEqual(readLocal("note.md"), "local edit")
        let remoteText = try await readRemote("note.md")
        XCTAssertEqual(remoteText, "remote edit")
        let parked = SyncState.conflictFileURL(key: "note.md", root: tempRoot)
        XCTAssertEqual(String(decoding: try Data(contentsOf: parked), as: UTF8.self), "remote edit")
        XCTAssertEqual(try SyncEngine.openConflicts(root: tempRoot, identity: context.identity).map(\.key), ["note.md"])

        // The key is skipped until resolved.
        let again = try await engine.run(context: context)
        XCTAssertEqual(again, SyncReport())
        XCTAssertEqual(readLocal("note.md"), "local edit")
    }

    func testDeleteVersusEditIsConflict() async throws {
        try writeLocal("note.md", "base")
        try await engine.run(context: context)
        try fm.removeItem(at: tempRoot.appendingPathComponent("note.md"))
        try await putRemote("note.md", "remote edit")

        let report = try await engine.run(context: context)
        XCTAssertEqual(report.newConflicts, ["note.md"])
        XCTAssertNil(readLocal("note.md"), "local delete is not undone")
        let remoteText = try await readRemote("note.md")
        XCTAssertEqual(remoteText, "remote edit", "remote edit is not deleted")
    }

    func testResolveKeepLocal() async throws {
        try await makeConflict()
        try await engine.resolveConflict(key: "note.md", choice: .keepLocal, context: context)

        let remoteText = try await readRemote("note.md")
        XCTAssertEqual(remoteText, "local edit")
        XCTAssertEqual(readLocal("note.md"), "local edit")
        try assertResolved("note.md")
        let followUp = try await engine.run(context: context)
        XCTAssertEqual(followUp, SyncReport())
    }

    func testResolveKeepRemote() async throws {
        try await makeConflict()
        try await engine.resolveConflict(key: "note.md", choice: .keepRemote, context: context)

        XCTAssertEqual(readLocal("note.md"), "remote edit")
        try assertResolved("note.md")
        let followUp = try await engine.run(context: context)
        XCTAssertEqual(followUp, SyncReport())
    }

    func testResolveKeepBoth() async throws {
        try await makeConflict()
        try await engine.resolveConflict(key: "note.md", choice: .keepBoth, context: context)

        XCTAssertEqual(readLocal("note.md"), "local edit")
        XCTAssertEqual(readLocal("note (remote).md"), "remote edit")
        let remoteOriginal = try await readRemote("note.md")
        let remoteCopy = try await readRemote("note (remote).md")
        XCTAssertEqual(remoteOriginal, "local edit")
        XCTAssertEqual(remoteCopy, "remote edit")
        try assertResolved("note.md")
        let followUp = try await engine.run(context: context)
        XCTAssertEqual(followUp, SyncReport())
    }

    func testKeepBothCopyKeepsTheOriginalsDocType() async throws {
        try await makeConflict()
        NoteMetadataStore.shared.setDocType(.checklist, for: tempRoot.appendingPathComponent("note.md"))
        try await engine.resolveConflict(key: "note.md", choice: .keepBoth, context: context)

        let copy = tempRoot.appendingPathComponent("note (remote).md")
        XCTAssertEqual(NoteMetadataStore.shared.docType(for: copy), .checklist)
    }

    func testKeepBothUniquifiesTakenName() async throws {
        try writeLocal("note (remote).md", "already here")
        try await makeConflict()
        try await engine.resolveConflict(key: "note.md", choice: .keepBoth, context: context)

        XCTAssertEqual(readLocal("note (remote).md"), "already here")
        XCTAssertEqual(readLocal("note (remote 2).md"), "remote edit")
    }

    func testResolveKeepLocalWhenLocalDeletedRemovesRemote() async throws {
        try writeLocal("note.md", "base")
        try await engine.run(context: context)
        try fm.removeItem(at: tempRoot.appendingPathComponent("note.md"))
        try await putRemote("note.md", "remote edit")
        try await engine.run(context: context)

        try await engine.resolveConflict(key: "note.md", choice: .keepLocal, context: context)
        let remoteText = try await readRemote("note.md")
        XCTAssertNil(remoteText)
        try assertResolved("note.md")
    }

    func testResolvingUnknownKeyThrows() async throws {
        do {
            try await engine.resolveConflict(key: "nope.md", choice: .keepLocal, context: context)
            XCTFail("expected noSuchConflict")
        } catch let error as SyncEngineError {
            XCTAssertEqual(error, .noSuchConflict("nope.md"))
        }
    }

    /// The conflict is gone from state and its parked remote copy is removed.
    private func assertResolved(_ key: String, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(try state().hasConflict(key), file: file, line: line)
        XCTAssertFalse(fm.fileExists(atPath: SyncState.conflictFileURL(key: key, root: tempRoot).path), file: file, line: line)
    }

    // MARK: - First sync and identity

    func testIdenticalContentFirstSyncIsNoop() async throws {
        try writeLocal("same.md", "identical")
        try await putRemote("same.md", "identical")

        let report = try await engine.run(context: context)
        XCTAssertEqual(report, SyncReport())
        XCTAssertNotNil(try state().entries["same.md"], "base recorded so later edits propagate")
        XCTAssertTrue(try state().conflicts.isEmpty)
    }

    func testConfigIdentityChangeDoesNotDelete() async throws {
        try writeLocal("keep.md", "precious")
        try await engine.run(context: context)

        // Point at a different, empty bucket: the old base must not read as "deleted remotely".
        let otherBucket = InMemoryObjectStore()
        let other = SyncContext(store: otherBucket, root: tempRoot, identity: "http://s3.test|other|")
        let report = try await engine.run(context: other)

        XCTAssertEqual(report.uploaded, ["keep.md"])
        XCTAssertTrue(report.deletedLocal.isEmpty)
        XCTAssertEqual(readLocal("keep.md"), "precious")
    }

    func testStateAndConflictsAreNeverUploaded() async throws {
        try writeLocal(SyncEngine.metadataKey, #"{"version":1,"notes":{}}"#)
        try await makeConflict()
        try writeLocal(".thoughtqueue/conflicts/stray.md", "parked")
        try writeLocal("notes.txt", "not a note")
        try await engine.run(context: context)

        let keys = try await remote.list(prefix: "").map(\.key)
        XCTAssertTrue(keys.contains(SyncEngine.metadataKey), "metadata.json syncs")
        XCTAssertFalse(keys.contains { $0.hasSuffix(SyncState.fileName) })
        XCTAssertFalse(keys.contains { $0.contains("conflicts/") })
        XCTAssertFalse(keys.contains("notes.txt"))
    }

    func testUnsyncableRemoteKeysAreIgnored() async throws {
        try await putRemote(".thoughtqueue/sync-state.json", "{}")
        try await putRemote("../escape.md", "nope")
        try await putRemote("image.png", "png")

        let report = try await engine.run(context: context)
        XCTAssertEqual(report, SyncReport())
        XCTAssertFalse(fm.fileExists(atPath: tempRoot.deletingLastPathComponent().appendingPathComponent("escape.md").path))
    }

    // MARK: - Seeding and triggers

    func testSeedCacheMergesWithoutOverwriting() throws {
        let source = fm.temporaryDirectory.appendingPathComponent("tq-seed-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: source) }
        try writeLocal("a.md", "from folder", root: source)
        try writeLocal("Work/b.md", "from folder", root: source)
        try writeLocal("a.md", "already cached")

        let copied = try SyncEngine.seedCache(from: source, into: tempRoot)
        XCTAssertEqual(copied, ["Work/b.md"])
        XCTAssertEqual(readLocal("a.md"), "already cached")
        XCTAssertEqual(readLocal("Work/b.md"), "from folder")
    }

    func testSyncNowCoalescesRequestsAndReportsStatus() async throws {
        let context = self.context!
        engine.contextProvider = { context }
        try writeLocal("a.md", "x")

        var statuses: [SyncStatus] = []
        let token = NotificationCenter.default.addObserver(forName: .syncStatusDidChange, object: engine, queue: nil) { [unowned self] _ in
            MainActor.assumeIsolated { statuses.append(self.engine.status) }
        }
        defer { NotificationCenter.default.removeObserver(token) }

        engine.syncNow()
        engine.syncNow()
        engine.syncNow()
        for _ in 0..<200 where statuses.count < 4 {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertEqual(statuses, [.syncing, .idle, .syncing, .idle], "three requests coalesce into one follow-up run")
        XCTAssertNotNil(engine.lastSyncDate)
        let remoteText = try await readRemote("a.md")
        XCTAssertEqual(remoteText, "x")
    }

    func testSyncNowWithoutConfigReportsError() {
        engine.contextProvider = { nil }
        engine.syncNow()
        XCTAssertEqual(engine.status, .error(SyncEngineError.notConfigured.localizedDescription))
    }
}
