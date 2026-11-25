import Foundation
import CryptoKit
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "SyncEngine")

extension Notification.Name {
    /// Posted on main whenever `SyncEngine.status` or `lastSyncDate` changes.
    static let syncStatusDidChange = Notification.Name("syncStatusDidChange")
    /// Posted on main when a sync records new conflicts. `userInfo["keys"]` is `[String]`.
    static let syncConflictsDetected = Notification.Name("syncConflictsDetected")
    /// Posted on main whenever the open-conflict list changes (new conflicts or a resolution).
    static let syncConflictsDidChange = Notification.Name("syncConflictsDidChange")
}

/// What the engine is doing right now.
enum SyncStatus: Equatable {
    case idle
    case syncing
    case error(String)
}

/// How the user chose to settle a conflict.
enum ConflictResolution {
    /// Local wins: upload it (or delete the remote if local is gone).
    case keepLocal
    /// Remote wins: write it locally (or delete local if remote is gone).
    case keepRemote
    /// Keep both: the remote copy is saved beside the note as "Name (remote).md".
    case keepBoth
}

enum SyncEngineError: LocalizedError, Equatable {
    case notConfigured
    case noSuchConflict(String)
    case invalidKey(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "S3 sync is not configured (mode, endpoint, bucket, access key or secret missing)."
        case .noSuchConflict(let key): return "There is no open sync conflict for \(key)."
        case .invalidKey(let key): return "\(key) is not a syncable path."
        }
    }
}

/// Everything one sync run needs. Injected so tests can run against an in-memory store and a
/// temp folder without touching UserDefaults or the Keychain.
struct SyncContext {
    let store: ObjectStore
    let root: URL
    /// `SyncState.identity(for:)` of the S3 config, scoping the base state.
    let identity: String
}

/// What a run or resolution changed, by key.
struct SyncReport: Equatable {
    var uploaded: [String] = []
    var downloaded: [String] = []
    var deletedLocal: [String] = []
    var deletedRemote: [String] = []
    var newConflicts: [String] = []

    /// Whether any file under the root was written or removed.
    var changedLocalFiles: Bool { !downloaded.isEmpty || !deletedLocal.isEmpty }
}

/// Bi-directional sync between the store root and an `ObjectStore`.
///
/// Main-actor isolated: runs are serialized through a task chain, network calls suspend rather
/// than block, and the local file work is small (markdown notes). Conflicts are never resolved
/// automatically; the remote side is parked in `SyncState.conflictFileURL` and the key is
/// skipped until `resolveConflict` is called.
@MainActor
final class SyncEngine {
    static let shared = SyncEngine()

    /// Store-relative keys of the two sidecar files that sync alongside notes.
    nonisolated static let metadataKey = "\(NoteMetadataStore.folderName)/\(NoteMetadataStore.fileName)"
    nonisolated static let settingsKey = "\(NoteMetadataStore.folderName)/settings.plist"
    /// Seconds of quiet after a local change before a sync starts.
    static let changeDebounce: TimeInterval = 3

    private(set) var status: SyncStatus = .idle
    private(set) var lastSyncDate: Date?

    /// Builds the context for triggered runs. Production reads Preferences and the Keychain;
    /// tests can replace it.
    var contextProvider: () throws -> SyncContext? = { try SyncEngine.contextFromPreferences() }

    /// Tail of the serial chain every run and resolution is appended to.
    private var tail: Task<Void, Never>?
    /// A triggered run is in flight; further requests set `rerunRequested` instead.
    private var isSyncing = false
    private var rerunRequested = false
    private var debounceItem: DispatchWorkItem?
    private var timer: Timer?
    private var observers: [NSObjectProtocol] = []
    /// True while the engine posts its own `.notesDidChange`, so the change trigger ignores it.
    private var isPostingOwnChange = false

    /// Internal so tests can build an isolated engine; the app uses `shared`.
    init() {}

    // MARK: - Triggers

    /// Begins observing triggers and runs the launch sync when enabled. Called once from
    /// `AppDelegate` after the store root is set. Safe to call again (it is a no-op).
    func start() {
        guard observers.isEmpty else { return }
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: .notesDidChange, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.notesDidChange() }
        })
        observers.append(nc.addObserver(forName: .syncConfigDidChange, object: nil, queue: .main) { [weak self] _ in
            // Deferred one runloop turn so AppDelegate's root switch (same notification) lands first.
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.rearmTimer() } }
        })
        rearmTimer()
        if PreferencesManager.shared.syncAtLaunch {
            requestSync(userInitiated: false)
        }
    }

    /// Runs a sync now. Unlike automatic triggers, a missing configuration is reported as an error status.
    func syncNow() {
        debounceItem?.cancel()
        requestSync(userInitiated: true)
    }

    /// Debounces local edits into one sync when `syncOnChange` is on.
    private func notesDidChange() {
        guard !isPostingOwnChange, PreferencesManager.shared.syncOnChange else { return }
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.requestSync(userInitiated: false) }
        }
        debounceItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.changeDebounce, execute: item)
    }

    /// Replaces the interval timer to match the current preferences (none in `.local` mode).
    private func rearmTimer() {
        timer?.invalidate()
        timer = nil
        let prefs = PreferencesManager.shared
        guard prefs.storageMode != .local, prefs.syncOnInterval else { return }
        timer = Timer.scheduledTimer(withTimeInterval: prefs.syncInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSync(userInitiated: false) }
        }
    }

    /// Starts a triggered run, or marks a follow-up run if one is already going.
    /// Automatic triggers are inert when sync is not configured.
    private func requestSync(userInitiated: Bool) {
        if isSyncing {
            rerunRequested = true
            return
        }
        let context: SyncContext
        do {
            guard let built = try contextProvider() else {
                if userInitiated { setStatus(.error(SyncEngineError.notConfigured.localizedDescription)) }
                return
            }
            context = built
        } catch {
            log.error("Sync context unavailable: \(error.localizedDescription, privacy: .public)")
            setStatus(.error(error.localizedDescription))
            return
        }

        isSyncing = true
        setStatus(.syncing)
        Task { @MainActor in
            do {
                try await self.run(context: context)
                self.lastSyncDate = Date()
                self.setStatus(.idle)
            } catch {
                log.error("Sync failed: \(error.localizedDescription, privacy: .public)")
                self.setStatus(.error(SyncErrorMessage.describe(error)))
            }
            self.isSyncing = false
            if self.rerunRequested {
                self.rerunRequested = false
                self.requestSync(userInitiated: false)
            }
        }
    }

    /// Updates `status` and announces it.
    private func setStatus(_ newStatus: SyncStatus) {
        status = newStatus
        NotificationCenter.default.post(name: .syncStatusDidChange, object: self)
    }

    /// The production context: nil in `.local` mode, when the config or secret is missing, or
    /// while the store root does not match the mode (mid-switch), so nothing syncs the wrong folder.
    nonisolated static func contextFromPreferences() throws -> SyncContext? {
        let prefs = PreferencesManager.shared
        guard prefs.storageMode != .local,
              let config = prefs.s3Config,
              let root = NoteStore.shared.rootURL,
              let expected = prefs.effectiveStoreURL,
              root.standardizedFileURL.path == expected.standardizedFileURL.path else { return nil }
        guard let secret = try prefs.s3SecretKey(), !secret.isEmpty else { return nil }
        return SyncContext(store: S3Client(config: config, secretKey: secret),
                           root: root,
                           identity: SyncState.identity(for: config))
    }

    // MARK: - Conflicts API

    /// Open conflicts for the current store and S3 config, oldest first. Empty when sync is
    /// not configured or the state file cannot be read (the read error is logged).
    func openConflicts() -> [SyncState.Conflict] {
        guard let root = NoteStore.shared.rootURL, let config = PreferencesManager.shared.s3Config else { return [] }
        do {
            return try Self.openConflicts(root: root, identity: SyncState.identity(for: config))
        } catch {
            log.error("Could not read sync state: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }

    /// Open conflicts recorded in `root`'s state for `identity`.
    nonisolated static func openConflicts(root: URL, identity: String) throws -> [SyncState.Conflict] {
        try SyncState.load(root: root, identity: identity).conflicts
    }

    /// Settles a conflict using the production context.
    func resolveConflict(key: String, choice: ConflictResolution) async throws {
        guard let context = try contextProvider() else { throw SyncEngineError.notConfigured }
        try await resolveConflict(key: key, choice: choice, context: context)
    }

    /// Settles a conflict against an explicit context. Serialized with sync runs.
    func resolveConflict(key: String, choice: ConflictResolution, context: SyncContext) async throws {
        try await serialized { try await self.performResolve(key: key, choice: choice, context: context) }
    }

    // MARK: - Running

    /// Runs one full sync against `context`, serialized with any other run or resolution.
    @discardableResult
    func run(context: SyncContext) async throws -> SyncReport {
        try await serialized { try await self.performSync(context: context) }
    }

    /// Appends `operation` to the serial chain and waits for its result.
    private func serialized<T>(_ operation: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = tail
        let task = Task { @MainActor () async throws -> T in
            await previous?.value
            return try await operation()
        }
        tail = Task { @MainActor in _ = await task.result }
        return try await task.value
    }

    /// Scan, list, plan, apply, then persist state and announce what changed.
    private func performSync(context: SyncContext) async throws -> SyncReport {
        let root = context.root
        let original = try SyncState.load(root: root, identity: context.identity)
        var state = original
        var report = SyncReport()

        let localFiles = try Self.scanLocal(root: root)
        var localHashes: [String: String] = [:]
        for (key, url) in localFiles {
            localHashes[key] = Self.sha256Hex(try Data(contentsOf: url))
        }
        var remoteETags: [String: String] = [:]
        var remoteDates: [String: Date] = [:]
        for object in try await context.store.list(prefix: "") where Self.isSyncedKey(object.key) {
            remoteETags[object.key] = object.etag
            remoteDates[object.key] = object.lastModified
        }

        // The state outlives the notes folder. If every known note vanished at once, the folder was
        // most likely replaced or its drive is not ready, so start over rather than delete them all.
        let knownNotes = state.entries.keys.filter { $0 != Self.metadataKey && $0 != Self.settingsKey }
        let hasLocalNotes = localHashes.keys.contains { $0 != Self.metadataKey && $0 != Self.settingsKey }
        if knownNotes.count > 1, !hasLocalNotes {
            log.warning("All known notes are missing locally; resetting the sync base")
            state.entries = [:]
        }

        let actions = SyncPlanner.plan(local: localHashes, remote: remoteETags, base: state.entries,
                                       openConflicts: Set(state.conflicts.map(\.key)))
        do {
            for action in actions {
                try await apply(action, remoteDates: remoteDates, context: context, state: &state, report: &report)
            }
        } catch {
            // Keep whatever progress was made so finished actions are not redone as conflicts.
            do {
                try finish(state: state, original: original, report: report, root: root)
            } catch let saveError {
                log.error("Could not save sync state after failure: \(saveError.localizedDescription, privacy: .public)")
            }
            throw error
        }
        try finish(state: state, original: original, report: report, root: root)
        return report
    }

    /// Carries out one planned action and records the new base for its key.
    private func apply(_ action: SyncAction, remoteDates: [String: Date], context: SyncContext, state: inout SyncState, report: inout SyncReport) async throws {
        let root = context.root
        switch action {
        case .noop:
            return
        case .forget(let key):
            state.entries[key] = nil
        case .upload(let key):
            let data = try Data(contentsOf: try Self.localURL(forKey: key, root: root))
            let etag = try await context.store.put(key: key, data: data)
            state.entries[key] = SyncState.Entry(localHash: Self.sha256Hex(data), remoteETag: etag)
            report.uploaded.append(key)
        case .download(let key):
            let content = try await context.store.get(key: key)
            try Self.writeLocal(content.data, key: key, root: root)
            state.entries[key] = SyncState.Entry(localHash: Self.sha256Hex(content.data), remoteETag: content.etag)
            report.downloaded.append(key)
        case .deleteLocal(let key):
            try Self.removeLocal(key: key, root: root)
            state.entries[key] = nil
            report.deletedLocal.append(key)
        case .deleteRemote(let key):
            try await context.store.delete(key: key)
            state.entries[key] = nil
            report.deletedRemote.append(key)
        case .conflict(let key):
            try await recordConflictIfReal(key: key, remoteDate: remoteDates[key], context: context, state: &state, report: &report)
        }
    }

    /// Fetches both sides of a planned conflict. Identical bytes (or both gone) settle it
    /// silently; otherwise the remote copy is parked under `conflicts/` and the key is recorded.
    private func recordConflictIfReal(key: String, remoteDate: Date?, context: SyncContext, state: inout SyncState, report: inout SyncReport) async throws {
        let root = context.root
        let localData = try Self.readLocalIfExists(key: key, root: root)
        let remote = try await Self.getIfExists(key: key, store: context.store)

        switch (localData, remote) {
        case let (local?, remote?) where local == remote.data:
            state.entries[key] = SyncState.Entry(localHash: Self.sha256Hex(local), remoteETag: remote.etag)
            return
        case (nil, nil):
            state.entries[key] = nil
            return
        default:
            break
        }

        let parked = SyncState.conflictFileURL(key: key, root: root)
        if let remote {
            try FileManager.default.createDirectory(at: parked.deletingLastPathComponent(), withIntermediateDirectories: true)
            try remote.data.write(to: parked, options: .atomic)
        } else if FileManager.default.fileExists(atPath: parked.path) {
            try FileManager.default.removeItem(at: parked)
        }
        state.conflicts.append(SyncState.Conflict(key: key, detectedAt: Date(),
                                                  remoteModifiedAt: remote == nil ? nil : remoteDate))
        report.newConflicts.append(key)
    }

    /// Applies the user's choice for one conflicted key, then clears the conflict.
    private func performResolve(key: String, choice: ConflictResolution, context: SyncContext) async throws {
        let root = context.root
        let original = try SyncState.load(root: root, identity: context.identity)
        guard original.hasConflict(key) else { throw SyncEngineError.noSuchConflict(key) }
        var state = original
        var report = SyncReport()

        let localData = try Self.readLocalIfExists(key: key, root: root)
        let remote = try await Self.getIfExists(key: key, store: context.store)

        switch (choice, localData, remote) {
        case (.keepLocal, _, _), (.keepBoth, _, nil):
            try await pushLocal(key: key, data: localData, context: context, state: &state, report: &report)
        case (.keepRemote, _, _), (.keepBoth, nil, _):
            try pullRemote(key: key, remote: remote, root: root, state: &state, report: &report)
        case let (.keepBoth, local?, remote?):
            if local != remote.data {
                let copyKey = try Self.remoteCopyKey(for: key, root: root, taken: Set(state.entries.keys))
                try Self.writeLocal(remote.data, key: copyKey, root: root)
                // The copy is the same note, so it keeps the original's document type
                // (otherwise a checklist's remote copy would reopen as markdown).
                let originalURL = try Self.localURL(forKey: key, root: root)
                if let type = NoteMetadataStore.shared.docType(for: originalURL) {
                    NoteMetadataStore.shared.setDocType(type, for: try Self.localURL(forKey: copyKey, root: root))
                }
                report.downloaded.append(copyKey)
                if Self.isSyncedKey(copyKey) {
                    let etag = try await context.store.put(key: copyKey, data: remote.data)
                    state.entries[copyKey] = SyncState.Entry(localHash: Self.sha256Hex(remote.data), remoteETag: etag)
                    report.uploaded.append(copyKey)
                }
            }
            try await pushLocal(key: key, data: local, context: context, state: &state, report: &report)
        }

        state.conflicts.removeAll { $0.key == key }
        let parked = SyncState.conflictFileURL(key: key, root: root)
        if FileManager.default.fileExists(atPath: parked.path) {
            try FileManager.default.removeItem(at: parked)
        }
        try finish(state: state, original: original, report: report, root: root)
    }

    /// Uploads `data` under `key`, or deletes the remote object when local is gone.
    private func pushLocal(key: String, data: Data?, context: SyncContext, state: inout SyncState, report: inout SyncReport) async throws {
        if let data {
            let etag = try await context.store.put(key: key, data: data)
            state.entries[key] = SyncState.Entry(localHash: Self.sha256Hex(data), remoteETag: etag)
            report.uploaded.append(key)
        } else {
            try await context.store.delete(key: key)
            state.entries[key] = nil
            report.deletedRemote.append(key)
        }
    }

    /// Writes the remote body locally, or deletes the local file when remote is gone.
    private func pullRemote(key: String, remote: ObjectContent?, root: URL, state: inout SyncState, report: inout SyncReport) throws {
        if let remote {
            try Self.writeLocal(remote.data, key: key, root: root)
            state.entries[key] = SyncState.Entry(localHash: Self.sha256Hex(remote.data), remoteETag: remote.etag)
            report.downloaded.append(key)
        } else {
            try Self.removeLocal(key: key, root: root)
            state.entries[key] = nil
            report.deletedLocal.append(key)
        }
    }

    /// Saves the state if it changed, refreshes caches for replaced sidecar files, and posts
    /// `.notesDidChange` (once) and the conflict notifications as needed.
    private func finish(state: SyncState, original: SyncState, report: SyncReport, root: URL) throws {
        // Skipping unchanged writes keeps an idle sync from producing watcher events.
        if state != original || !FileManager.default.fileExists(atPath: SyncState.fileURL(root: root).path) {
            try state.save(root: root)
        }

        let touched = Set(report.downloaded + report.deletedLocal)
        let isActiveRoot = NoteStore.shared.rootURL?.standardizedFileURL.path == root.standardizedFileURL.path
        if touched.contains(Self.metadataKey) {
            NoteMetadataStore.shared.invalidateCache()
        }
        if touched.contains(Self.settingsKey), isActiveRoot {
            SettingsSync.shared.importFromStore()
        }
        if report.changedLocalFiles {
            isPostingOwnChange = true
            NoteStore.shared.postChange()
            isPostingOwnChange = false
        }
        if !report.newConflicts.isEmpty {
            NotificationCenter.default.post(name: .syncConflictsDetected, object: self,
                                            userInfo: ["keys": report.newConflicts])
        }
        if state.conflicts != original.conflicts {
            NotificationCenter.default.post(name: .syncConflictsDidChange, object: self)
        }
    }

    // MARK: - Local file helpers

    /// Whether a store-relative key belongs to the synced set: a non-hidden `.md` note at any
    /// depth, or one of the two sidecar files. Rejects empty, `.`/`..` and hidden components,
    /// so a remote key can never point outside the root or into `.thoughtqueue/`.
    nonisolated static func isSyncedKey(_ key: String) -> Bool {
        if key == metadataKey || key == settingsKey { return true }
        let components = key.split(separator: "/", omittingEmptySubsequences: false)
        guard let last = components.last, !components.isEmpty else { return false }
        guard components.allSatisfy({ !$0.isEmpty && !$0.hasPrefix(".") }) else { return false }
        return (String(last) as NSString).pathExtension.lowercased() == "md"
    }

    /// The local file for a synced key. Throws for keys outside the synced set.
    nonisolated static func localURL(forKey key: String, root: URL) throws -> URL {
        guard isSyncedKey(key) else { throw SyncEngineError.invalidKey(key) }
        return root.appendingPathComponent(key)
    }

    /// Every synced file under `root`, keyed by '/'-separated root-relative path. Uses the same
    /// rules as `NoteStore` (hidden entries skipped, `.md` files at any depth) plus the sidecars.
    nonisolated static func scanLocal(root: URL) throws -> [String: URL] {
        var result: [String: URL] = [:]
        try collect(in: root, keyPrefix: "", into: &result)
        for key in [metadataKey, settingsKey] {
            let url = root.appendingPathComponent(key)
            if FileManager.default.fileExists(atPath: url.path) { result[key] = url }
        }
        return result
    }

    /// Recursive walk behind `scanLocal`.
    nonisolated private static func collect(in dir: URL, keyPrefix: String, into result: inout [String: URL]) throws {
        let entries = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey],
                                                                  options: [.skipsHiddenFiles])
        for entry in entries {
            let key = keyPrefix + entry.lastPathComponent
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                try collect(in: entry, keyPrefix: key + "/", into: &result)
            } else if isSyncedKey(key) {
                result[key] = entry
            }
        }
    }

    /// The local bytes for a key, or nil when the file does not exist.
    nonisolated static func readLocalIfExists(key: String, root: URL) throws -> Data? {
        let url = try localURL(forKey: key, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Writes a downloaded body atomically, creating intermediate folders (new categories) and
    /// registering the write so the folder watcher does not echo it.
    nonisolated static func writeLocal(_ data: Data, key: String, root: URL) throws {
        let url = try localURL(forKey: key, root: root)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        NoteStore.shared.registerSelfWrite(url)
        try data.write(to: url, options: .atomic)
    }

    /// Deletes a local file if it exists, registering the change with the watcher.
    nonisolated static func removeLocal(key: String, root: URL) throws {
        let url = try localURL(forKey: key, root: root)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        NoteStore.shared.registerSelfWrite(url)
        try FileManager.default.removeItem(at: url)
    }

    /// A free key beside `key` for the remote copy: "Name (remote).md", then "Name (remote 2).md", ...
    /// A key is free when no local file exists and the base state does not know it.
    nonisolated static func remoteCopyKey(for key: String, root: URL, taken: Set<String>) throws -> String {
        let nsKey = key as NSString
        let dir = nsKey.deletingLastPathComponent
        let ext = nsKey.pathExtension
        let stem = (nsKey.lastPathComponent as NSString).deletingPathExtension
        for counter in 1...999 {
            let suffix = counter == 1 ? " (remote)" : " (remote \(counter))"
            let name = stem + suffix + (ext.isEmpty ? "" : "." + ext)
            let candidate = dir.isEmpty ? name : dir + "/" + name
            let url = root.appendingPathComponent(candidate)
            if !taken.contains(candidate), !FileManager.default.fileExists(atPath: url.path) {
                return candidate
            }
        }
        throw SyncEngineError.invalidKey(key)
    }

    /// Downloads an object, mapping a 404 to nil.
    nonisolated static func getIfExists(key: String, store: ObjectStore) async throws -> ObjectContent? {
        do {
            return try await store.get(key: key)
        } catch S3ClientError.service(404, _, _), S3ClientError.http(404) {
            return nil
        }
    }

    /// Lowercase hex SHA256 of `data`.
    nonisolated static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Seeding the S3 cache

    /// Copies the synced files of `source` (the user's local folder) into the S3 cache, so
    /// switching to `.s3` mode carries existing notes along. Merge only: files already in the
    /// cache, or keys the cache's base state knows about, are left alone. The next sync sees
    /// the copied files as unsynced, so it uploads them, or records a conflict when the bucket
    /// already has different content under the same key. Returns the copied keys.
    @discardableResult
    nonisolated static func seedCache(from source: URL, into cache: URL) throws -> [String] {
        let fm = FileManager.default
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let known = try SyncState.loadAnyIdentity(root: cache)?.entries ?? [:]
        var copied: [String] = []
        for (key, url) in try scanLocal(root: source).sorted(by: { $0.key < $1.key }) where known[key] == nil {
            let destination = try localURL(forKey: key, root: cache)
            guard !fm.fileExists(atPath: destination.path) else { continue }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: url, to: destination)
            copied.append(key)
        }
        return copied
    }
}
