import Foundation

/// The sync engine's memory of the last successful sync, stored at
/// `<root>/.thoughtqueue/sync-state.json`. It is device-local and never uploaded.
///
/// Each entry is the "base" a three-way comparison needs: the local SHA256 and the remote ETag
/// the key had when both sides last agreed. A key with no entry has never been synced, so a
/// missing file on one side is never read as a deletion.
///
/// The state is scoped to `configIdentity` (endpoint + bucket + prefix). Pointing the app at a
/// different bucket starts from an empty base instead of reading the new bucket's missing keys
/// as deletions.
struct SyncState: Codable, Equatable {
    /// What both sides looked like the last time a key was in sync.
    struct Entry: Codable, Equatable {
        /// Lowercase hex SHA256 of the local file's bytes.
        var localHash: String
        /// The remote object's ETag (quotes stripped).
        var remoteETag: String
    }

    /// A key both sides changed. It is skipped by sync until the user resolves it.
    struct Conflict: Codable, Equatable {
        var key: String
        var detectedAt: Date
    }

    static let fileName = "sync-state.json"
    /// Folder (under `.thoughtqueue/`) holding the remote side of each open conflict.
    static let conflictsFolderName = "conflicts"

    var configIdentity: String
    var entries: [String: Entry] = [:]
    var conflicts: [Conflict] = []

    /// The identity a state file is scoped to: endpoint, bucket and normalized prefix.
    static func identity(for config: S3Config) -> String {
        "\(config.endpoint.absoluteString)|\(config.bucket)|\(config.normalizedPrefix)"
    }

    /// `<root>/.thoughtqueue/sync-state.json`.
    static func fileURL(root: URL) -> URL {
        root.appendingPathComponent(NoteMetadataStore.folderName, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// `<root>/.thoughtqueue/conflicts/<key>`, where the remote copy of a conflicted key is kept.
    static func conflictFileURL(key: String, root: URL) -> URL {
        root.appendingPathComponent(NoteMetadataStore.folderName, isDirectory: true)
            .appendingPathComponent(conflictsFolderName, isDirectory: true)
            .appendingPathComponent(key)
    }

    /// Loads the state for `root`. A missing file, or one written for a different identity,
    /// yields a fresh empty state for `identity`. An unreadable file throws rather than being
    /// silently replaced, because an empty base would turn every pending delete into a copy.
    static func load(root: URL, identity: String) throws -> SyncState {
        let url = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return SyncState(configIdentity: identity)
        }
        let data = try Data(contentsOf: url)
        let state = try decoder.decode(SyncState.self, from: data)
        guard state.configIdentity == identity else { return SyncState(configIdentity: identity) }
        return state
    }

    /// Reads whatever state file exists regardless of identity, or nil when there is none.
    static func loadAnyIdentity(root: URL) throws -> SyncState? {
        let url = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(SyncState.self, from: Data(contentsOf: url))
    }

    /// Writes the state atomically, registering the write so the folder watcher ignores it.
    func save(root: URL) throws {
        let url = Self.fileURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(self)
        NoteStore.shared.registerSelfWrite(url)
        try data.write(to: url, options: .atomic)
    }

    /// Whether `key` currently has an open conflict.
    func hasConflict(_ key: String) -> Bool {
        conflicts.contains { $0.key == key }
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
