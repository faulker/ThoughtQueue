import Foundation

/// What the conflict window says about one conflict, derived from its key and both copies.
struct ConflictDetails: Equatable {
    enum Side { case local, remote }

    var title: String
    /// Folder the note is in, or nil for the app's own sidecar files.
    var category: String?
    var localModified: Date?
    var remoteModified: Date?

    /// The more recent side, or nil when either date is unknown or they match.
    var newer: Side? {
        guard let localModified, let remoteModified, localModified != remoteModified else { return nil }
        return localModified > remoteModified ? .local : .remote
    }

    /// Builds the details for `conflict`, reading the local file's modification date.
    static func load(_ conflict: SyncState.Conflict, root: URL) throws -> ConflictDetails {
        let url = try SyncEngine.localURL(forKey: conflict.key, root: root)
        var modified: Date?
        if FileManager.default.fileExists(atPath: url.path) {
            modified = try FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date
        }
        return ConflictDetails(title: title(forKey: conflict.key), category: category(forKey: conflict.key),
                               localModified: modified, remoteModified: conflict.remoteModifiedAt)
    }

    /// A note's title, or a plain name for a sidecar file.
    static func title(forKey key: String) -> String {
        switch key {
        case SyncEngine.metadataKey: return "Note types and archived folders"
        case SyncEngine.settingsKey: return "App settings"
        default: return ((key as NSString).lastPathComponent as NSString).deletingPathExtension
        }
    }

    /// The note's folder, "Uncategorized" at the root, or nil for a sidecar file.
    static func category(forKey key: String) -> String? {
        if key == SyncEngine.metadataKey || key == SyncEngine.settingsKey { return nil }
        let folder = (key as NSString).deletingLastPathComponent
        return folder.isEmpty ? Note.uncategorized : folder
    }

    /// "edited Nov 24, 2026 at 9:41 AM, 1 KB", or "deleted" when that copy is gone.
    static func sideDescription(verb: String, date: Date?, text: String?) -> String {
        guard let text else { return "deleted" }
        let when = date.map { "\(verb) " + $0.formatted(date: .abbreviated, time: .shortened) } ?? "date unknown"
        let size = ByteCountFormatter.string(fromByteCount: Int64(text.utf8.count), countStyle: .file)
        return "\(when), \(size)"
    }

    /// Zero-based line numbers that differ between the two texts, per side.
    static func changedLines(local: String, remote: String) -> (local: Set<Int>, remote: Set<Int>) {
        let localLines = local.components(separatedBy: "\n")
        let remoteLines = remote.components(separatedBy: "\n")
        var result: (local: Set<Int>, remote: Set<Int>) = ([], [])
        for change in remoteLines.difference(from: localLines) {
            switch change {
            case .remove(let offset, _, _): result.local.insert(offset)
            case .insert(let offset, _, _): result.remote.insert(offset)
            }
        }
        return result
    }
}
