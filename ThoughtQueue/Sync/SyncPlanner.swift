import Foundation

/// One step the sync engine should take for a key.
enum SyncAction: Equatable {
    /// Local changed (or is new), remote did not: send local up.
    case upload(String)
    /// Remote changed (or is new), local did not: bring remote down.
    case download(String)
    /// Remote was deleted and local is unchanged since the last sync.
    case deleteLocal(String)
    /// Local was deleted and remote is unchanged since the last sync.
    case deleteRemote(String)
    /// Both sides diverged from the base (or there is no base and both exist). The engine
    /// compares the actual bytes first and only records a real conflict when they differ.
    case conflict(String)
    /// Deleted on both sides: drop the base entry.
    case forget(String)
    /// In sync.
    case noop(String)

    /// The key the action applies to.
    var key: String {
        switch self {
        case .upload(let k), .download(let k), .deleteLocal(let k), .deleteRemote(let k),
             .conflict(let k), .forget(let k), .noop(let k):
            return k
        }
    }
}

/// Pure three-way sync planner. No filesystem, no network: it only compares hashes and ETags.
enum SyncPlanner {
    /// Decides what to do for every key seen locally, remotely, or in the base state.
    ///
    /// - Parameters:
    ///   - local: key to SHA256 hex of the local file.
    ///   - remote: key to remote ETag.
    ///   - base: the last-synced state per key.
    ///   - openConflicts: keys awaiting user resolution; they get no action at all.
    /// - Returns: actions sorted by key. Data is never lost: a delete is only planned when the
    ///   other side is unchanged since the base, and never when there is no base.
    static func plan(local: [String: String],
                     remote: [String: String],
                     base: [String: SyncState.Entry],
                     openConflicts: Set<String>) -> [SyncAction] {
        let keys = Set(local.keys).union(remote.keys).union(base.keys).subtracting(openConflicts)
        return keys.sorted().map { key in
            action(key: key, local: local[key], remote: remote[key], base: base[key])
        }
    }

    /// The decision table for a single key.
    private static func action(key: String, local: String?, remote: String?, base: SyncState.Entry?) -> SyncAction {
        guard let base else {
            switch (local, remote) {
            case (.some, .some): return .conflict(key)
            case (.some, .none): return .upload(key)
            case (.none, .some): return .download(key)
            case (.none, .none): return .noop(key)
            }
        }

        let localChanged = local != base.localHash
        let remoteChanged = remote != base.remoteETag

        switch (local, remote) {
        case (.none, .none):
            return .forget(key)
        case (.none, .some):
            return remoteChanged ? .conflict(key) : .deleteRemote(key)
        case (.some, .none):
            return localChanged ? .conflict(key) : .deleteLocal(key)
        case (.some, .some):
            switch (localChanged, remoteChanged) {
            case (false, false): return .noop(key)
            case (true, false): return .upload(key)
            case (false, true): return .download(key)
            case (true, true): return .conflict(key)
            }
        }
    }
}
