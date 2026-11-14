package com.thoughtqueue.app.sync

import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.prefs.SyncSettings
import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Covers the Storage & Sync form validation, mode gating and the mode-to-root mapping. */
class SyncFormTest {
    private val valid = SyncForm(
        endpoint = "http://localhost:9000", bucket = "notes", accessKeyId = "AKIA", secretInput = "s3cret",
    )

    /** An empty form reports every required field and cannot save. */
    @Test
    fun emptyFormHasErrors() {
        val e = SyncForm().errors()
        assertEquals("Required", e.endpoint)
        assertEquals("Required", e.bucket)
        assertEquals("Required", e.accessKeyId)
        assertFalse(SyncForm().canSave)
    }

    /** A complete form is valid and builds a config with the default region. */
    @Test
    fun validFormBuildsConfig() {
        assertTrue(valid.canSave)
        assertEquals("us-east-1", valid.s3Config()?.region)
    }

    /** Endpoints without an http(s) scheme or host get a format error. */
    @Test
    fun badEndpointIsRejected() {
        assertNotNull(valid.copy(endpoint = "localhost:9000").errors().endpoint)
        assertNotNull(valid.copy(endpoint = "ftp://host").errors().endpoint)
        assertNull(valid.copy(endpoint = "https://s3.amazonaws.com").errors().endpoint)
        assertNull(valid.copy(endpoint = "bad").s3Config())
    }

    /** A non-numeric interval is an error; a low one is accepted but flagged and clamped on save. */
    @Test
    fun intervalValidationAndClamp() {
        assertNotNull(valid.copy(intervalText = "").errors().interval)
        val low = valid.copy(intervalText = "5")
        assertTrue(low.canSave)
        assertTrue(low.intervalWillClamp)
        assertEquals(15, low.toSettings().intervalMinutes)
        assertEquals(60, valid.copy(intervalText = "60").toSettings().intervalMinutes)
    }

    /** A secret counts when typed or already stored. */
    @Test
    fun hasSecret() {
        assertTrue(valid.hasSecret)
        assertFalse(valid.copy(secretInput = " ").hasSecret)
        assertTrue(valid.copy(secretInput = "", secretSaved = true).hasSecret)
    }

    /** Settings round-trip through the form, trimming whitespace. */
    @Test
    fun settingsRoundTrip() {
        val s = SyncSettings(endpoint = "http://h", bucket = "b", accessKeyId = "k", intervalMinutes = 30, pathStyle = false)
        assertEquals(s, SyncForm.from(s, true).toSettings())
        assertEquals("b", SyncForm.from(s.copy(bucket = " b "), false).toSettings().bucket)
    }

    /** S3 and Both need a valid saved config and a saved secret; Local always works. */
    @Test
    fun modeGating() {
        val good = valid.toSettings()
        assertNull(SyncForm.modeBlockReason(StorageMode.LOCAL, SyncSettings(), false))
        for (m in listOf(StorageMode.S3, StorageMode.BOTH)) {
            assertNotNull(SyncForm.modeBlockReason(m, SyncSettings(), true))
            assertNotNull(SyncForm.modeBlockReason(m, good, false))
            assertNull(SyncForm.modeBlockReason(m, good, true))
        }
    }

    /** Local and Both share notes/, S3 uses the s3cache/ folder. */
    @Test
    fun modeToRoot() {
        val files = File("/data/files")
        assertEquals(File(files, "notes"), StorageMode.LOCAL.storeRoot(files))
        assertEquals(File(files, "notes"), StorageMode.BOTH.storeRoot(files))
        assertEquals(File(files, "s3cache"), StorageMode.S3.storeRoot(files))
        assertEquals(StorageMode.LOCAL, StorageMode.fromRaw("bogus"))
    }
}
