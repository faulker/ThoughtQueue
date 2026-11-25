import CryptoKit
import Foundation
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "SyncState")

/// The sync engine's memory of the last successful sync, stored at
/// `~/Library/Application Support/ThoughtQueue/SyncState/<root hash>/sync-state.json`. It is
/// device-local and never uploaded. It is kept out of the notes folder because that folder may
/// itself be shared by another sync service (Google Drive, iCloud), and devices overwriting each
/// other's base would produce false conflicts and wrong deletes.
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
        /// When the bucket's copy was uploaded, if known. Nil when it was deleted, or when the
        /// conflict was recorded by an older version.
        var remoteModifiedAt: Date?
    }

    static let fileName = "sync-state.json"
    /// Folder (beside the state file) holding the remote side of each open conflict.
    static let conflictsFolderName = "conflicts"

    var configIdentity: String
    var entries: [String: Entry] = [:]
    var conflicts: [Conflict] = []

    /// The identity a state file is scoped to: endpoint, bucket and normalized prefix.
    static func identity(for config: S3Config) -> String {
        "\(config.endpoint.absoluteString)|\(config.bucket)|\(config.normalizedPrefix)"
    }

    /// Folder holding one subfolder of state per notes root. Under XCTest it is a temp folder, so
    /// tests never touch the real Application Support.
    static let baseURL: URL = {
        if NSClassFromString("XCTestCase") != nil {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("tq-sync-state-\(UUID().uuidString)", isDirectory: true)
        }
        return PreferencesManager.s3CacheURL.deletingLastPathComponent()
            .appendingPathComponent("SyncState", isDirectory: true)
    }()

    /// This device's state folder for `root`, named by a hash of the root's resolved path.
    static func directory(root: URL) -> URL {
        var path = root.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") { path.removeFirst("/private".count) }
        let hash = SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        return baseURL.appendingPathComponent(hash, isDirectory: true)
    }

    /// The state file for `root`.
    static func fileURL(root: URL) -> URL {
        directory(root: root).appendingPathComponent(fileName)
    }

    /// Where the remote copy of a conflicted key is parked.
    static func conflictFileURL(key: String, root: URL) -> URL {
        directory(root: root)
            .appendingPathComponent(conflictsFolderName, isDirectory: true)
            .appendingPathComponent(key)
    }

    /// Moves state written by older versions out of `<root>/.thoughtqueue/`, but only for the
    /// private S3 cache. A user-chosen folder may be shared with other devices, so its old file
    /// may describe another device's files; trusting it could turn a file that has not arrived
    /// here yet into a remote delete. Those start from an empty base, which never deletes.
    static func migrateLegacy(root: URL, cacheURL: URL = PreferencesManager.s3CacheURL) throws {
        guard root.standardizedFileURL.path == cacheURL.standardizedFileURL.path else { return }
        let fm = FileManager.default
        let legacy = root.appendingPathComponent(NoteMetadataStore.folderName, isDirectory: true)
        let target = directory(root: root)
        let oldState = legacy.appendingPathComponent(fileName)
        guard fm.fileExists(atPath: oldState.path), !fm.fileExists(atPath: fileURL(root: root).path) else { return }
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        // Parked copies first: the state file's presence is what marks the migration done.
        let oldConflicts = legacy.appendingPathComponent(conflictsFolderName, isDirectory: true)
        let newConflicts = target.appendingPathComponent(conflictsFolderName, isDirectory: true)
        if fm.fileExists(atPath: oldConflicts.path), !fm.fileExists(atPath: newConflicts.path) {
            try fm.moveItem(at: oldConflicts, to: newConflicts)
        }
        try fm.moveItem(at: oldState, to: fileURL(root: root))
        log.info("Moved sync state out of the S3 cache folder")
    }

    /// Loads the state for `root`. A missing file, or one written for a different identity,
    /// yields a fresh empty state for `identity`. An unreadable file throws rather than being
    /// silently replaced, because an empty base would turn every pending delete into a copy.
    static func load(root: URL, identity: String) throws -> SyncState {
        try migrateLegacy(root: root)
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
        try migrateLegacy(root: root)
        let url = fileURL(root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(SyncState.self, from: Data(contentsOf: url))
    }

    /// Writes the state atomically.
    func save(root: URL) throws {
        let url = Self.fileURL(root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(self)
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
