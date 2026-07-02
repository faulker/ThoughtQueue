import Foundation
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "NoteStore")

extension Notification.Name {
    /// Posted whenever the set of notes or their metadata changes (app writes or external edits).
    static let notesDidChange = Notification.Name("notesDidChange")
}

/// Filesystem-backed note store. Replaces the old SQLite DatabaseManager.
/// The store folder is the single source of truth: notes are plain `.md` files,
/// categories are immediate subfolders, dates are file attributes. No DB, no sidecar.
final class NoteStore {
    static let shared = NoteStore()

    /// The store root folder. Set via PreferencesManager; can be overridden in tests.
    var rootURL: URL? {
        didSet {
            if let url = rootURL { ensureRootExists(url) }
        }
    }

    /// Pending self-written paths the watcher should ignore once each.
    /// Keyed on the standardized path; the value is a small pending count plus the
    /// registration time. A matching FSEvent consumes one pending count and clears the
    /// entry, so a genuine external edit arriving later is NOT suppressed. A long safety
    /// TTL only prunes entries whose event never arrived (e.g. coalesced away).
    private struct SelfWriteEntry {
        var pending: Int
        var registeredAt: Date
    }
    private var selfWrites: [String: SelfWriteEntry] = [:]
    private let selfWriteLock = NSLock()
    /// Safety net only: prune stale entries whose matching event never came.
    private let selfWriteTTL: TimeInterval = 10.0

    private let fm = FileManager.default

    private init() {}

    // MARK: - Self-write suppression

    /// Record that the app is about to write `url`, so the watcher can ignore the resulting event.
    /// Multiple writes to the same path before an event arrives accumulate pending counts.
    func registerSelfWrite(_ url: URL) {
        selfWriteLock.lock()
        defer { selfWriteLock.unlock() }
        let key = url.standardizedFileURL.path
        prune_locked()
        if var entry = selfWrites[key] {
            entry.pending += 1
            entry.registeredAt = Date()
            selfWrites[key] = entry
        } else {
            selfWrites[key] = SelfWriteEntry(pending: 1, registeredAt: Date())
        }
    }

    /// True if `path` matches a pending self-write. Consumes one pending count and clears
    /// the entry when it reaches zero, so the next event for that path is treated as external.
    func wasSelfWrite(_ path: String) -> Bool {
        selfWriteLock.lock()
        defer { selfWriteLock.unlock() }
        prune_locked()
        let key = URL(fileURLWithPath: path).standardizedFileURL.path
        guard var entry = selfWrites[key] else { return false }
        entry.pending -= 1
        if entry.pending <= 0 {
            selfWrites.removeValue(forKey: key)
        } else {
            selfWrites[key] = entry
        }
        return true
    }

    /// Drop entries whose matching event never arrived within the safety TTL.
    private func prune_locked() {
        let now = Date()
        selfWrites = selfWrites.filter { now.timeIntervalSince($0.value.registeredAt) < selfWriteTTL }
    }

    // MARK: - Root management

    private func ensureRootExists(_ url: URL) {
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private func requireRoot() -> URL? {
        guard let root = rootURL else {
            log.error("NoteStore used with no rootURL set")
            return nil
        }
        return root
    }

    // MARK: - Reads

    /// All category names (immediate subfolders), sorted. Does not include Uncategorized.
    func categories() -> [String] {
        guard let root = requireRoot() else { return [] }
        guard let entries = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return []
        }
        var names: [String] = []
        for entry in entries {
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue {
                names.append(entry.lastPathComponent)
            }
        }
        return names.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// All notes across the whole store, newest first by modified date.
    func allNotes() -> [Note] {
        guard let root = requireRoot() else { return [] }
        var result: [Note] = []
        collectNotes(in: root, root: root, into: &result)
        return result.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    /// Notes for a given category. Pass nil for Uncategorized (root-level notes only).
    func notes(in category: String?) -> [Note] {
        return allNotes().filter { $0.category == category }
    }

    private func collectNotes(in dir: URL, root: URL, into result: inout [Note]) {
        guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else {
            return
        }
        for entry in entries {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                collectNotes(in: entry, root: root, into: &result)
            } else if let note = Note.from(url: entry, storeRoot: root) {
                result.append(note)
            }
        }
    }

    /// Read the full markdown body of a note.
    func body(of note: Note) -> String {
        (try? String(contentsOf: note.url, encoding: .utf8)) ?? ""
    }

    // MARK: - Naming

    /// Sanitize a category name so it can never escape or nest outside the store root.
    /// Strips path separators and `..`, trims whitespace/dots, and collapses to a single
    /// safe folder name. Returns nil when the input normalizes to empty (caller treats
    /// nil as Uncategorized). Centralized so every entry point shares one guard.
    static func sanitizeCategory(_ raw: String?) -> String? {
        guard let raw = raw else { return nil }
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name != Note.uncategorized else { return nil }

        // Replace any path separators with a space, then drop NUL and control chars.
        name = name.replacingOccurrences(of: "/", with: " ")
        name = name.replacingOccurrences(of: "\\", with: " ")
        name = name.replacingOccurrences(of: ":", with: " ")
        name = String(name.unicodeScalars.filter { !$0.properties.isDefaultIgnorableCodePoint && $0.value >= 0x20 })

        // Collapse internal whitespace runs.
        let parts = name.split(whereSeparator: { $0 == " " || $0.isNewline })
        name = parts.joined(separator: " ")

        // Trim leading/trailing dots and whitespace so `..`, `.`, ` . ` cannot survive.
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: ". "))

        // Reject anything that still reduces to a traversal token or empty.
        guard !name.isEmpty, name != "." , name != ".." else { return nil }
        return name
    }

    /// Slugify a string into a safe filename stem (no extension).
    /// Keeps it readable: lowercased, spaces to hyphens, strips path-unsafe chars.
    static func slug(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        // Take the first line only.
        let firstLine = trimmed.split(whereSeparator: \.isNewline).first.map(String.init) ?? trimmed

        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: " -_")
        let filtered = String(firstLine.unicodeScalars.filter { allowed.contains($0) })

        let collapsed = filtered
            .lowercased()
            .split(whereSeparator: { $0 == " " || $0 == "-" })
            .joined(separator: "-")

        // Cap length so filenames stay reasonable.
        let capped = String(collapsed.prefix(60))
        return capped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    /// Resolve a non-colliding file URL for the given stem inside `folder`.
    /// If `<stem>.md` exists, append a numeric counter, then a timestamp as last resort.
    func uniqueURL(stem: String, in folder: URL) -> URL {
        let base = stem.isEmpty ? Self.timestampStem() : stem
        var candidate = folder.appendingPathComponent("\(base).md")
        if !fm.fileExists(atPath: candidate.path) { return candidate }

        for counter in 2...999 {
            candidate = folder.appendingPathComponent("\(base)-\(counter).md")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
        }
        // Final fallback: a UUID suffix can never collide, so this never overwrites.
        for _ in 0..<5 {
            let unique = folder.appendingPathComponent("\(base)-\(UUID().uuidString.prefix(8)).md")
            if !fm.fileExists(atPath: unique.path) { return unique }
        }
        return folder.appendingPathComponent("\(base)-\(UUID().uuidString).md")
    }

    /// A timestamp-based filename stem, used when no title is available.
    static func timestampStem() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return "note-\(f.string(from: Date()))"
    }

    // MARK: - Writes

    /// Folder URL for a category name; nil/empty means the store root (Uncategorized).
    /// Always sanitizes the name first so it can never escape the store root (rule #1).
    private func folderURL(for category: String?) -> URL? {
        guard let root = requireRoot() else { return nil }
        guard let safe = Self.sanitizeCategory(category) else { return root }
        let folder = root.appendingPathComponent(safe, isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    /// Create a new note. `title` becomes the filename (slugified); empty falls back to
    /// the first body line, then a timestamp. Returns the created Note or nil on failure.
    @discardableResult
    func createNote(title: String, body: String, category: String?) -> Note? {
        guard let folder = folderURL(for: category), let root = rootURL else { return nil }

        var stem = Self.slug(title)
        if stem.isEmpty { stem = Self.slug(body) }
        let url = uniqueURL(stem: stem, in: folder)

        registerSelfWrite(url)
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            log.error("createNote write failed: \(error.localizedDescription)")
            return nil
        }
        let note = Note.from(url: url, storeRoot: root)
        postChange()
        return note
    }

    /// Append text to an existing note, separated by a blank line. Returns true on success.
    @discardableResult
    func append(to note: Note, text: String) -> Bool {
        guard fm.fileExists(atPath: note.url.path) else {
            log.warning("append target missing: \(note.url.path)")
            return false
        }
        let existing = body(of: note)
        let separator = existing.isEmpty ? "" : "\n\n"
        let combined = existing + separator + text

        registerSelfWrite(note.url)
        do {
            try combined.write(to: note.url, atomically: true, encoding: .utf8)
        } catch {
            log.error("append write failed: \(error.localizedDescription)")
            return false
        }
        postChange()
        return true
    }

    /// Overwrite the body of an existing note. Aborts if the file was deleted/moved
    /// externally, so we never recreate a stale path (rule #6).
    @discardableResult
    func updateBody(of note: Note, body: String) -> Bool {
        guard fm.fileExists(atPath: note.url.path) else {
            log.warning("updateBody target missing, aborting: \(note.url.path)")
            return false
        }
        registerSelfWrite(note.url)
        do {
            try body.write(to: note.url, atomically: true, encoding: .utf8)
        } catch {
            log.error("updateBody failed: \(error.localizedDescription)")
            return false
        }
        postChange()
        return true
    }

    /// Rename a note's title (its filename). Returns the new Note or nil on failure.
    /// Aborts if the source vanished externally (rule #6).
    @discardableResult
    func rename(_ note: Note, to newTitle: String) -> Note? {
        guard fm.fileExists(atPath: note.url.path) else {
            log.warning("rename source missing, aborting: \(note.url.path)")
            return nil
        }
        guard let root = rootURL else { return nil }
        let folder = note.url.deletingLastPathComponent()
        var stem = Self.slug(newTitle)
        if stem.isEmpty { stem = Self.timestampStem() }
        let dest = uniqueURL(stem: stem, in: folder)

        registerSelfWrite(note.url)
        registerSelfWrite(dest)
        do {
            try fm.moveItem(at: note.url, to: dest)
        } catch {
            log.error("rename failed: \(error.localizedDescription)")
            return nil
        }
        let renamed = Note.from(url: dest, storeRoot: root)
        postChange()
        return renamed
    }

    /// Move a note to a different category (folder). Pass nil for Uncategorized (root).
    /// Aborts if the source vanished externally (rule #6).
    @discardableResult
    func move(_ note: Note, to category: String?) -> Note? {
        guard fm.fileExists(atPath: note.url.path) else {
            log.warning("move source missing, aborting: \(note.url.path)")
            return nil
        }
        guard let root = rootURL, let folder = folderURL(for: category) else { return nil }
        let dest = uniqueURL(stem: note.url.deletingPathExtension().lastPathComponent, in: folder)

        registerSelfWrite(note.url)
        registerSelfWrite(dest)
        do {
            try fm.moveItem(at: note.url, to: dest)
        } catch {
            log.error("move failed: \(error.localizedDescription)")
            return nil
        }
        let moved = Note.from(url: dest, storeRoot: root)
        postChange()
        return moved
    }

    /// Delete a note.
    @discardableResult
    func delete(_ note: Note) -> Bool {
        registerSelfWrite(note.url)
        do {
            try fm.removeItem(at: note.url)
        } catch {
            log.error("delete failed: \(error.localizedDescription)")
            return false
        }
        postChange()
        return true
    }

    /// Create a new category folder. Rejects names that sanitize to empty/traversal (rule #1).
    /// Returns true if created or already exists.
    @discardableResult
    func createCategory(_ name: String) -> Bool {
        guard let safe = Self.sanitizeCategory(name) else { return false }
        guard let folder = folderURL(for: safe) else { return false }
        let ok = fm.fileExists(atPath: folder.path)
        if ok { postChange() }
        return ok
    }

    // MARK: - Notifications

    private func postChange() {
        if Thread.isMainThread {
            NotificationCenter.default.post(name: .notesDidChange, object: nil)
        } else {
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .notesDidChange, object: nil)
            }
        }
    }
}
