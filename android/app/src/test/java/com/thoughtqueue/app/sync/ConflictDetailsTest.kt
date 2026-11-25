package com.thoughtqueue.app.sync

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files
import java.time.Instant

/** Conflict descriptions, and where per-device sync state lives. */
class ConflictDetailsTest {
    private lateinit var temp: File
    private lateinit var root: File

    @Before fun setUp() {
        temp = Files.createTempDirectory("tq-details").toFile()
        root = File(temp, "notes").also { it.mkdirs() }
    }

    @After fun tearDown() {
        SyncState.baseDir = null
        temp.deleteRecursively()
    }

    @Test fun titlesAndCategories() {
        assertEquals("My plan", ConflictDetails.title("Work/My plan.md"))
        assertEquals("Work", ConflictDetails.category("Work/My plan.md"))
        assertEquals("Uncategorized", ConflictDetails.category("a.md"))
        assertEquals("App settings", ConflictDetails.title(SyncEngine.SETTINGS_KEY))
        assertNull(ConflictDetails.category(SyncEngine.METADATA_KEY))
    }

    @Test fun loadsBothSidesAndPicksTheNewer() {
        File(root, "a.md").apply { writeText("local"); setLastModified(1_000_000) }
        SyncState.conflictFile("a.md", root).apply { parentFile!!.mkdirs(); writeText("remote") }
        fun load(at: Instant?) = ConflictDetails.load(SyncState.Conflict("a.md", Instant.EPOCH, at), root)
        assertEquals("local", load(null).local)
        assertEquals("remote", load(null).remote)
        assertNull(load(null).newer)
        assertEquals(ConflictDetails.Side.REMOTE, load(Instant.ofEpochMilli(2_000_000)).newer)
        assertEquals(ConflictDetails.Side.LOCAL, load(Instant.ofEpochMilli(500_000)).newer)
    }

    @Test fun sideDescriptions() {
        assertEquals("deleted", ConflictDetails.sideDescription("edited", Instant.EPOCH, null))
        assertEquals("date unknown, 2 bytes", ConflictDetails.sideDescription("uploaded", null, "xy"))
        assertTrue(ConflictDetails.sideDescription("edited", Instant.EPOCH, "xy").startsWith("edited "))
    }

    @Test fun uploadDateRoundTrips() {
        val state = SyncState("x", conflicts = listOf(SyncState.Conflict("a.md", Instant.EPOCH, Instant.ofEpochSecond(5))))
        assertTrue(state.encode().contains("\"key\" : \"a.md\",\n      \"remoteModifiedAt\" : \"1970-01-01T00:00:05Z\"\n"))
        assertEquals(state, SyncState.decode(state.encode()))
    }

    @Test fun oldStateMovesOutOfTheNotesFolderWithParkedCopies() {
        val state = SyncState("x", conflicts = listOf(SyncState.Conflict("a.md", Instant.EPOCH)))
        state.save(root)
        val legacy = SyncState.fileOf(root)
        SyncState.conflictFile("a.md", root).apply { parentFile!!.mkdirs(); writeText("parked") }

        SyncState.baseDir = File(temp, "state")
        assertEquals(state, SyncState.load(root, "x"))
        assertFalse(legacy.exists())
        assertFalse(SyncState.fileOf(root).path.startsWith(root.path + "/"))
        assertEquals("parked", SyncState.conflictFile("a.md", root).readText())
    }
}
