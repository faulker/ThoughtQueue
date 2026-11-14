package com.thoughtqueue.app.sync

/** One step the sync engine should take for a key. */
sealed class SyncAction {
    /** The key the action applies to. */
    abstract val key: String

    /** Local changed (or is new), remote did not: send local up. */
    data class Upload(override val key: String) : SyncAction()

    /** Remote changed (or is new), local did not: bring remote down. */
    data class Download(override val key: String) : SyncAction()

    /** Remote was deleted and local is unchanged since the last sync. */
    data class DeleteLocal(override val key: String) : SyncAction()

    /** Local was deleted and remote is unchanged since the last sync. */
    data class DeleteRemote(override val key: String) : SyncAction()

    /**
     * Both sides diverged from the base (or there is no base and both exist). The engine
     * compares the actual bytes first and only records a real conflict when they differ.
     */
    data class Conflict(override val key: String) : SyncAction()

    /** Deleted on both sides: drop the base entry. */
    data class Forget(override val key: String) : SyncAction()

    /** In sync. */
    data class Noop(override val key: String) : SyncAction()
}

/**
 * Pure three-way sync planner, a port of the desktop's `Sync/SyncPlanner.swift`. No filesystem,
 * no network: it only compares hashes and ETags. The table is the one in `docs/sync.md`.
 */
object SyncPlanner {
    /**
     * Decides what to do for every key seen locally, remotely, or in the base state.
     *
     * [local] maps key to the SHA256 hex of the local file, [remote] maps key to the remote ETag,
     * [base] is the last-synced state per key, and [openConflicts] are keys awaiting user
     * resolution, which get no action at all. Actions are sorted by key. Data is never lost: a
     * delete is only planned when the other side is unchanged since the base, and never when
     * there is no base.
     */
    fun plan(
        local: Map<String, String>,
        remote: Map<String, String>,
        base: Map<String, SyncState.Entry>,
        openConflicts: Set<String>,
    ): List<SyncAction> {
        val keys = (local.keys + remote.keys + base.keys) - openConflicts
        return keys.sorted().map { action(it, local[it], remote[it], base[it]) }
    }

    /** The decision table for a single key. */
    private fun action(key: String, local: String?, remote: String?, base: SyncState.Entry?): SyncAction {
        if (base == null) {
            return when {
                local != null && remote != null -> SyncAction.Conflict(key)
                local != null -> SyncAction.Upload(key)
                remote != null -> SyncAction.Download(key)
                else -> SyncAction.Noop(key)
            }
        }

        val localChanged = local != base.localHash
        val remoteChanged = remote != base.remoteETag

        return when {
            local == null && remote == null -> SyncAction.Forget(key)
            local == null -> if (remoteChanged) SyncAction.Conflict(key) else SyncAction.DeleteRemote(key)
            remote == null -> if (localChanged) SyncAction.Conflict(key) else SyncAction.DeleteLocal(key)
            !localChanged && !remoteChanged -> SyncAction.Noop(key)
            localChanged && !remoteChanged -> SyncAction.Upload(key)
            !localChanged -> SyncAction.Download(key)
            else -> SyncAction.Conflict(key)
        }
    }
}
