package com.thoughtqueue.app.sync

import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.prefs.SyncSettings

/**
 * One-line summaries shown under the Settings rows. Pure (no Android types) so they are
 * unit-testable; the caller formats the last-sync time.
 */
object SyncSummary {
    /** The display title for a storage mode. */
    fun modeTitle(mode: StorageMode): String = when (mode) {
        StorageMode.LOCAL -> "Local only"
        StorageMode.S3 -> "S3 only"
        StorageMode.BOTH -> "Local + S3"
    }

    /** The Storage & Sync row summary: the mode, then the sync error or last sync time. */
    fun storage(mode: StorageMode, status: SyncStatus, lastSyncText: String?): String {
        val title = modeTitle(mode)
        if (!mode.syncs) return title
        val detail = when (status) {
            SyncStatus.Syncing -> "Syncing..."
            is SyncStatus.Error -> "Sync error"
            SyncStatus.Idle -> lastSyncText?.let { "Last sync $it" } ?: "Not synced yet"
        }
        return "$title · $detail"
    }

    /** The S3 connection row summary: the bucket (or "Not set up") and whether a secret is saved. */
    fun connection(saved: SyncSettings, secretSaved: Boolean): String {
        if (saved.s3Config() == null) return "Not set up"
        return saved.bucket + if (secretSaved) " · Secret saved" else " · No secret key"
    }
}
