import Foundation
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "NoteMetadata")

/// How a note is presented. Recorded explicitly rather than guessed from content.
enum NoteDocType: String, Codable {
    /// An ordinary markdown document, even if it happens to contain task lines.
    case markdown
    /// A checkbox list, presented by `ChecklistViewController`.
    case checklist
}

/// Explicit per-note metadata for the store folder.
///
/// Notes stay plain markdown files: nothing here touches a note's bytes. This is one sidecar,
/// `.thoughtqueue/metadata.json`, in the same hidden folder as the settings mirror, recording
/// facts about a note that cannot be read off its content. Today that is one fact: whether the
/// note is a checkbox list or a markdown document.
///
/// Content is never consulted. A note with no recorded type is a markdown document, full stop:
/// two notes that both read as nothing but `- [ ]` lines can be one person's checklist and
/// another's scratch pad, and no rule over the bytes can tell them apart. Only "+ List" and an
/// explicit "Edit as Checklist" make a list, so typing a checkbox into a note can never convert
/// it, and neither can deleting the last one convert it back.
///
/// Keys are store-relative paths, so the file survives moving the whole store folder. The app's
/// own renames and moves remap keys; an external move loses the entry and falls back to
/// inference, which is self-healing rather than wrong.
final class NoteMetadataStore {
    static let shared = NoteMetadataStore()

    /// One note's recorded facts. A struct rather than a bare enum so more can be added later
    /// without a format break; unknown keys in the file are dropped on rewrite.
    struct Entry: Codable, Equatable {
        var type: NoteDocType?
    }

    /// The on-disk shape of `.thoughtqueue/metadata.json`.
    struct File: Codable, Equatable {
        var version: Int
        var notes: [String: Entry]

        static let currentVersion = 1
        static let empty = File(version: currentVersion, notes: [:])
    }

    static let folderName = ".thoughtqueue"
    static let fileName = "metadata.json"

    private let fm = FileManager.default
    private let lock = NSLock()
    /// Cached file contents plus the root they were loaded from, so switching store folders
    /// (or a test swapping `rootURL`) re-reads rather than serving another store's metadata.
    private var cache: File?
    private var cachedRoot: URL?

    private init() {}

    // MARK: - Paths

    private var root: URL? { NoteStore.shared.rootURL?.standardizedFileURL }

    /// The metadata file inside the current store folder, or nil when no store root is set.
    var fileURL: URL? {
        guard let root else { return nil }
        return root.appendingPathComponent(Self.folderName, isDirectory: true)
            .appendingPathComponent(Self.fileName)
    }

    /// Store-relative key for a URL, or nil when it does not live under `root`.
    /// Pure so key handling is testable without a filesystem.
    ///
    /// Both sides are normalized first. The store root is often reached through a symlink
    /// (`/tmp` and `/var` are the obvious ones on macOS) while directory enumeration hands back
    /// the resolved path, so comparing the two as written would never match.
    static func key(for url: URL, root: URL) -> String? {
        let rootPath = normalizedPath(root)
        let path = normalizedPath(url)
        guard path.hasPrefix(rootPath + "/") else { return nil }
        let relative = String(path.dropFirst(rootPath.count + 1))
        return relative.isEmpty ? nil : relative
    }

    /// Resolve symlinks, then drop a leading `/private` the way `standardizedFileURL` does.
    /// Doing that step textually is deliberate: `standardizedFileURL` only strips the prefix for
    /// a path that exists, and these keys are computed for files that have just been moved away
    /// from where they were, so an existence-dependent rule would normalize the two sides of a
    /// move differently and lose the entry.
    private static func normalizedPath(_ url: URL) -> String {
        let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard resolved.hasPrefix("/private/") else { return resolved }
        return String(resolved.dropFirst("/private".count))
    }

    // MARK: - Resolution

    /// The type to present a note as. Nothing recorded means a markdown document; a note
    /// becomes a list only by being declared one.
    static func resolve(explicit: NoteDocType?) -> NoteDocType {
        explicit ?? .markdown
    }

    // MARK: - Reads

    /// The recorded type for a note URL, or nil when nothing was recorded.
    func docType(for url: URL) -> NoteDocType? {
        lock.lock()
        defer { lock.unlock() }
        guard let root, let key = Self.key(for: url, root: root) else { return nil }
        return load_locked().notes[key]?.type
    }

    // MARK: - Writes

    /// Record (or, with nil, clear) the type for a note URL.
    func setDocType(_ type: NoteDocType?, for url: URL) {
        mutate { root, file in
            guard let key = Self.key(for: url, root: root) else { return false }
            var entry = file.notes[key] ?? Entry()
            guard entry.type != type else { return false }
            entry.type = type
            if entry == Entry() {
                file.notes.removeValue(forKey: key)
            } else {
                file.notes[key] = entry
            }
            return true
        }
    }

    /// Carry a note's entry across a rename or a move to another category.
    func move(from oldURL: URL, to newURL: URL) {
        mutate { root, file in
            guard let oldKey = Self.key(for: oldURL, root: root),
                  let newKey = Self.key(for: newURL, root: root),
                  oldKey != newKey,
                  let entry = file.notes.removeValue(forKey: oldKey) else { return false }
            file.notes[newKey] = entry
            return true
        }
    }

    /// Drop a deleted note's entry so the file does not accumulate ghosts.
    func forget(_ url: URL) {
        mutate { root, file in
            guard let key = Self.key(for: url, root: root) else { return false }
            return file.notes.removeValue(forKey: key) != nil
        }
    }

    /// Re-key every entry under `oldFolder` to sit under `newFolder`, for a category rename.
    func moveFolder(from oldFolder: URL, to newFolder: URL) {
        mutate { root, file in
            guard let oldPrefix = Self.key(for: oldFolder, root: root),
                  let newPrefix = Self.key(for: newFolder, root: root),
                  oldPrefix != newPrefix else { return false }
            var changed = false
            for (key, entry) in file.notes where key.hasPrefix(oldPrefix + "/") {
                file.notes.removeValue(forKey: key)
                file.notes[newPrefix + String(key.dropFirst(oldPrefix.count))] = entry
                changed = true
            }
            return changed
        }
    }

    /// Forget everything under a folder, for a category delete whose notes did not survive.
    func forgetFolder(_ folder: URL) {
        mutate { root, file in
            guard let prefix = Self.key(for: folder, root: root) else { return false }
            let doomed = file.notes.keys.filter { $0.hasPrefix(prefix + "/") }
            guard !doomed.isEmpty else { return false }
            for key in doomed { file.notes.removeValue(forKey: key) }
            return true
        }
    }

    /// Drop the in-memory cache. Tests use this after swapping store roots by hand.
    func invalidateCache() {
        lock.lock()
        defer { lock.unlock() }
        cache = nil
        cachedRoot = nil
    }

    // MARK: - Persistence

    /// Apply `change` to the loaded file and write it back when it reported a real edit.
    private func mutate(_ change: (URL, inout File) -> Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let root else { return }
        var file = load_locked()
        guard change(root, &file) else { return }
        cache = file
        save_locked(file)
    }

    /// Read the file, or serve the cache when it belongs to the current root.
    private func load_locked() -> File {
        guard let root else { return .empty }
        if let cache, cachedRoot?.path == root.path { return cache }

        var file = File.empty
        if let url = fileURL, let data = try? Data(contentsOf: url) {
            if let decoded = try? JSONDecoder().decode(File.self, from: data) {
                file = decoded
            } else {
                log.error("metadata.json unreadable; starting fresh")
            }
        }
        cache = file
        cachedRoot = root
        return file
    }

    private func save_locked(_ file: File) {
        guard let url = fileURL else { return }
        let folder = url.deletingLastPathComponent()
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)

        let encoder = JSONEncoder()
        // Stable, readable output: the store folder usually rides a file-sync service, and a
        // reordered dictionary would look like a change on every write.
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(file) else { return }

        // The watcher sees this write like any other; claim it so it does not post a change.
        NoteStore.shared.registerSelfWrite(url)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("metadata write failed: \(error.localizedDescription)")
        }
    }
}
