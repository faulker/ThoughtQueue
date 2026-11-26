package com.thoughtqueue.app.sync

import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.prefs.SyncSettings
import org.junit.Assert.assertEquals
import org.junit.Test

/** Covers the one-line summaries on the Settings rows. */
class SyncSummaryTest {
    private val configured = SyncSettings(endpoint = "http://localhost:9000", bucket = "notes", accessKeyId = "AKIA")

    /** Local only never mentions sync state. */
    @Test
    fun localModeIsJustTheTitle() {
        assertEquals("Local only", SyncSummary.storage(StorageMode.LOCAL, SyncStatus.Error("boom"), "3:12 PM"))
    }

    /** A syncing mode shows the last sync time, or that it has not synced. */
    @Test
    fun syncingModeShowsLastSync() {
        assertEquals("S3 only · Last sync 3:12 PM", SyncSummary.storage(StorageMode.S3, SyncStatus.Idle, "3:12 PM"))
        assertEquals("Local + S3 · Not synced yet", SyncSummary.storage(StorageMode.BOTH, SyncStatus.Idle, null))
    }

    /** Errors and in-progress syncs take priority over the last sync time. */
    @Test
    fun statusOverridesLastSync() {
        assertEquals("S3 only · Sync error", SyncSummary.storage(StorageMode.S3, SyncStatus.Error("x"), "3:12 PM"))
        assertEquals("S3 only · Syncing...", SyncSummary.storage(StorageMode.S3, SyncStatus.Syncing, "3:12 PM"))
    }

    /** The connection row names the bucket and secret state, or says it is not set up. */
    @Test
    fun connectionSummary() {
        assertEquals("Not set up", SyncSummary.connection(SyncSettings(), secretSaved = true))
        assertEquals("notes · Secret saved", SyncSummary.connection(configured, secretSaved = true))
        assertEquals("notes · No secret key", SyncSummary.connection(configured, secretSaved = false))
    }
}
