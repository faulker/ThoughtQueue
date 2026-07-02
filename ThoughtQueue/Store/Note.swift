import Foundation

/// A note is a value type fully derived from its file URL on disk.
/// Nothing here is authoritative metadata cached elsewhere: title is the filename
/// (without extension), category is the immediate parent folder under the store root
/// (or "Uncategorized" when the file lives directly in the root), and dates come from
/// FileManager attributes. Reconstruct a `Note` from its URL on every read.
struct Note: Identifiable, Hashable {
    /// The absolute file URL is the stable identity of a note.
    let url: URL
    let title: String
    /// nil means the note is in the store root (Uncategorized).
    let category: String?
    let createdAt: Date
    let modifiedAt: Date

    var id: URL { url }

    /// Display name for the category, mapping nil to "Uncategorized".
    var categoryDisplay: String { category ?? Note.uncategorized }

    static let uncategorized = "Uncategorized"

    /// Build a Note from a file URL relative to the given store root.
    /// Returns nil if the URL is not a regular `.md` file under the root.
    static func from(url: URL, storeRoot: URL) -> Note? {
        guard url.pathExtension.lowercased() == "md" else { return nil }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return nil }

        let title = url.deletingPathExtension().lastPathComponent
        let category = Note.category(of: url, storeRoot: storeRoot)

        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let created = (attrs?[.creationDate] as? Date) ?? Date()
        let modified = (attrs?[.modificationDate] as? Date) ?? created

        return Note(url: url, title: title, category: category, createdAt: created, modifiedAt: modified)
    }

    /// Determine the category folder for a file URL under the store root.
    /// Only one level of nesting is meaningful; deeper paths use their first
    /// subfolder under the root as the category.
    private static func category(of url: URL, storeRoot: URL) -> String? {
        let parent = url.deletingLastPathComponent().standardizedFileURL
        let root = storeRoot.standardizedFileURL
        if parent.path == root.path { return nil }

        // Walk up to find the immediate child of root that contains this file.
        var current = parent
        while current.deletingLastPathComponent().path != root.path {
            let up = current.deletingLastPathComponent()
            if up.path == current.path { break } // reached filesystem root, give up
            current = up
        }
        let name = current.lastPathComponent
        return name.isEmpty ? nil : name
    }
}
