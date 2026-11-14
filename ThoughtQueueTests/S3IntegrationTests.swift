import XCTest
@testable import ThoughtQueue

/// Opt-in tests against a real S3-compatible server (RustFS, MinIO, AWS). Skipped unless
/// `TQ_S3_ENDPOINT`, `TQ_S3_BUCKET`, `TQ_S3_ACCESS_KEY` and `TQ_S3_SECRET_KEY` are set.
/// Optional: `TQ_S3_REGION` (default us-east-1), `TQ_S3_PATH_STYLE` (default true) and
/// `TQ_S3_PAGINATION=1` (uploads about 1000 objects to exercise list pagination).
/// With `xcodebuild`, pass them as `TEST_RUNNER_TQ_S3_ENDPOINT=...` and so on; see docs/sync.md.
/// Every object is written under a unique `tq-it-<UUID>/` prefix and removed in tearDown.
@MainActor
final class S3IntegrationTests: XCTestCase {
    private var client: S3Client!
    private var config: S3Config!
    private var tempRoot: URL!
    private let fm = FileManager.default

    /// Builds the client from the environment or skips the test.
    override func setUpWithError() throws {
        let env = ProcessInfo.processInfo.environment
        guard let endpoint = env["TQ_S3_ENDPOINT"], let url = URL(string: endpoint),
              let bucket = env["TQ_S3_BUCKET"],
              let access = env["TQ_S3_ACCESS_KEY"],
              let secret = env["TQ_S3_SECRET_KEY"] else {
            throw XCTSkip("Set TQ_S3_ENDPOINT, TQ_S3_BUCKET, TQ_S3_ACCESS_KEY, TQ_S3_SECRET_KEY to run S3 integration tests.")
        }
        let pathStyle = (env["TQ_S3_PATH_STYLE"] ?? "true").lowercased() != "false"
        config = S3Config(endpoint: url, region: env["TQ_S3_REGION"] ?? "us-east-1", bucket: bucket,
                          keyPrefix: "tq-it-\(UUID().uuidString)/", usePathStyle: pathStyle, accessKeyID: access)
        client = S3Client(config: config, secretKey: secret)

        tempRoot = fm.temporaryDirectory.appendingPathComponent("tq-it-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
    }

    /// Deletes every object under this run's prefix and the temp root.
    override func tearDown() async throws {
        if let client {
            let leftovers = (try? await client.list(prefix: "")) ?? []
            for object in leftovers { try? await client.delete(key: object.key) }
        }
        if let tempRoot { try? fm.removeItem(at: tempRoot) }
        if tempRoot != nil { NoteStore.shared.rootURL = nil }
    }

    // MARK: - Client

    /// put/list/get/delete with spaces, a category folder and unicode in the key.
    func testClientRoundTrip() async throws {
        try await client.testConnection()
        let keys = ["Work/My Note.md", "plain.md", "Idées/café ☕.md"]
        for key in keys {
            let etag = try await client.put(key: key, data: Data("body of \(key)".utf8))
            XCTAssertFalse(etag.isEmpty)
        }

        let listed = try await client.list(prefix: "")
        XCTAssertEqual(Set(listed.map(\.key)), Set(keys))
        let work = try await client.list(prefix: "Work/")
        XCTAssertEqual(work.map(\.key), ["Work/My Note.md"])

        for key in keys {
            let content = try await client.get(key: key)
            XCTAssertEqual(String(decoding: content.data, as: UTF8.self), "body of \(key)")
        }

        try await client.delete(key: "Work/My Note.md")
        try await client.delete(key: "Work/My Note.md") // deleting a missing key succeeds
        do {
            _ = try await client.get(key: "Work/My Note.md")
            XCTFail("expected NoSuchKey")
        } catch let error as S3ClientError {
            guard case .service(_, let code, _) = error else { return XCTFail("unexpected \(error)") }
            XCTAssertEqual(code, "NoSuchKey")
        }
    }

    /// Lists more than one page (servers cap a page at 1000 keys). Slow, so opt-in.
    func testListPagination() async throws {
        guard ProcessInfo.processInfo.environment["TQ_S3_PAGINATION"] == "1" else {
            throw XCTSkip("Set TQ_S3_PAGINATION=1 to upload about 1000 objects and test pagination.")
        }
        let total = 1005
        let client = self.client!
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func add() {
                guard next < total else { return }
                let key = String(format: "page/n%04d.md", next)
                next += 1
                group.addTask { _ = try await client.put(key: key, data: Data("x".utf8)) }
            }
            for _ in 0..<16 { add() }
            while try await group.next() != nil { add() }
        }
        let listed = try await client.list(prefix: "page/")
        XCTAssertEqual(listed.count, total)
        XCTAssertEqual(Set(listed.map(\.key)).count, total)
    }

    // MARK: - Engine

    /// Upload, remote edit down, delete propagation both ways, then a conflict, on a real server.
    func testEngineAgainstRealStore() async throws {
        let engine = SyncEngine()
        let context = SyncContext(store: client, root: tempRoot, identity: SyncState.identity(for: config))

        func writeLocal(_ key: String, _ text: String) throws {
            let url = tempRoot.appendingPathComponent(key)
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        func readLocal(_ key: String) -> String? {
            fm.contents(atPath: tempRoot.appendingPathComponent(key).path).map { String(decoding: $0, as: UTF8.self) }
        }
        func readRemote(_ key: String) async throws -> String? {
            try await SyncEngine.getIfExists(key: key, store: client).map { String(decoding: $0.data, as: UTF8.self) }
        }

        // Upload, including a category folder, a space and unicode.
        try writeLocal("Work/My Note.md", "v1")
        try writeLocal("café ☕.md", "latte")
        let up = try await engine.run(context: context)
        XCTAssertEqual(Set(up.uploaded), ["Work/My Note.md", "café ☕.md"])
        let remoteV1 = try await readRemote("Work/My Note.md")
        XCTAssertEqual(remoteV1, "v1")

        // Remote edit comes down.
        _ = try await client.put(key: "Work/My Note.md", data: Data("v2".utf8))
        let down = try await engine.run(context: context)
        XCTAssertEqual(down.downloaded, ["Work/My Note.md"])
        XCTAssertEqual(readLocal("Work/My Note.md"), "v2")

        // Local delete propagates up, remote delete propagates down.
        try fm.removeItem(at: tempRoot.appendingPathComponent("café ☕.md"))
        let delUp = try await engine.run(context: context)
        XCTAssertEqual(delUp.deletedRemote, ["café ☕.md"])
        let gone = try await readRemote("café ☕.md")
        XCTAssertNil(gone)
        try await client.delete(key: "Work/My Note.md")
        let delDown = try await engine.run(context: context)
        XCTAssertEqual(delDown.deletedLocal, ["Work/My Note.md"])
        XCTAssertNil(readLocal("Work/My Note.md"))

        // Conflict: both sides edit after a clean sync.
        try writeLocal("note.md", "base")
        _ = try await engine.run(context: context)
        try writeLocal("note.md", "local edit")
        _ = try await client.put(key: "note.md", data: Data("remote edit".utf8))
        let conflicted = try await engine.run(context: context)
        XCTAssertEqual(conflicted.newConflicts, ["note.md"])
        XCTAssertEqual(readLocal("note.md"), "local edit")

        try await engine.resolveConflict(key: "note.md", choice: .keepRemote, context: context)
        XCTAssertEqual(readLocal("note.md"), "remote edit")
        let followUp = try await engine.run(context: context)
        XCTAssertEqual(followUp, SyncReport())
    }
}
