package com.thoughtqueue.app.sync

import com.thoughtqueue.app.store.NoteDocType
import com.thoughtqueue.app.store.NoteStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * End-to-end sync tests: a temp store root against [InMemoryObjectStore], no network, no
 * preferences, no secret store. Ported from the desktop's `SyncEngineTests.swift`, plus the
 * Android-specific trigger and settings.plist cases.
 */
class SyncEngineTest {
    private lateinit var root: File
    private lateinit var remote: InMemoryObjectStore
    private lateinit var noteStore: NoteStore
    private lateinit var scope: CoroutineScope
    private lateinit var engine: SyncEngine
    private lateinit var context: SyncContext

    @Before fun setUp() {
        root = Files.createTempDirectory("tq-sync").toFile()
        remote = InMemoryObjectStore()
        noteStore = NoteStore(root)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        context = SyncContext(remote, root, "http://s3.test|bucket|")
        engine = SyncEngine(scope, contextProvider = { context }, noteStoreProvider = { noteStore })
    }

    @After fun tearDown() {
        scope.cancel()
        root.deleteRecursively()
    }

    // MARK: Helpers

    /** Writes a local file under [base], creating folders. */
    private fun writeLocal(key: String, text: String, base: File = root) {
        val f = File(base, key)
        f.parentFile!!.mkdirs()
        f.writeText(text)
    }

    /** Reads a local file under the root, or null when missing. */
    private fun readLocal(key: String): String? = File(root, key).takeIf { it.exists() }?.readText()

    /** Reads a remote object, or null when missing. */
    private suspend fun readRemote(key: String): String? = SyncEngine.getIfExists(key, remote)?.data?.let { String(it) }

    private suspend fun putRemote(key: String, text: String) {
        remote.put(key, text.toByteArray())
    }

    private fun state() = SyncState.load(root, context.identity)

    /** Syncs "note.md" to both sides, edits it on both, and runs the sync that records the conflict. */
    private suspend fun makeConflict(local: String = "local edit", remoteText: String = "remote edit") {
        writeLocal("note.md", "base")
        engine.run(context)
        writeLocal("note.md", local)
        putRemote("note.md", remoteText)
        engine.run(context)
        assertTrue(state().hasConflict("note.md"))
    }

    /** The conflict is gone from state and its parked remote copy is removed. */
    private fun assertResolved(key: String) {
        assertFalse(state().hasConflict(key))
        assertFalse(SyncState.conflictFile(key, root).exists())
        assertTrue(engine.conflicts.value.none { it.key == key })
    }

    // MARK: Propagation

    @Test fun uploadRoundTrip() = runBlocking {
        writeLocal("hello.md", "hi")
        writeLocal("Work/plan.md", "plan")

        val first = engine.run(context)
        assertEquals(setOf("hello.md", "Work/plan.md"), first.uploaded.toSet())
        assertEquals("hi", readRemote("hello.md"))
        assertEquals("plan", readRemote("Work/plan.md"))

        assertEquals("an unchanged store syncs to nothing", SyncReport(), engine.run(context))

        writeLocal("hello.md", "hi again")
        assertEquals(listOf("hello.md"), engine.run(context).uploaded)
        assertEquals("hi again", readRemote("hello.md"))
    }

    @Test fun downloadNewNoteInNewCategoryRefreshesStore() = runBlocking {
        putRemote("Ideas/new.md", "from elsewhere")
        val before = noteStore.changes.value

        val report = engine.run(context)

        assertEquals(listOf("Ideas/new.md"), report.downloaded)
        assertEquals("from elsewhere", readLocal("Ideas/new.md"))
        assertTrue("store change signal bumped", noteStore.changes.value > before)
        assertTrue("Ideas" in noteStore.categories())
        assertTrue(noteStore.allNotes().any { it.title == "new" && it.category == "Ideas" })
    }

    @Test fun remoteEditDownloads() = runBlocking {
        writeLocal("a.md", "v1")
        engine.run(context)
        putRemote("a.md", "v2")

        assertEquals(listOf("a.md"), engine.run(context).downloaded)
        assertEquals("v2", readLocal("a.md"))
    }

    @Test fun localDeletePropagatesToRemote() = runBlocking {
        writeLocal("gone.md", "x")
        engine.run(context)
        File(root, "gone.md").delete()

        assertEquals(listOf("gone.md"), engine.run(context).deletedRemote)
        assertNull(readRemote("gone.md"))
        assertNull(state().entries["gone.md"])
    }

    @Test fun remoteDeletePropagatesToLocal() = runBlocking {
        writeLocal("Work/gone.md", "x")
        engine.run(context)
        remote.delete("Work/gone.md")

        assertEquals(listOf("Work/gone.md"), engine.run(context).deletedLocal)
        assertNull(readLocal("Work/gone.md"))
    }

    @Test fun downloadedMetadataTakesEffect() = runBlocking {
        File(root, "Work").mkdirs()
        assertFalse(noteStore.isArchived("Work"))
        putRemote(SyncEngine.METADATA_KEY, """{"version":1,"notes":{},"folders":{"Work":{"archived":true}}}""")

        assertEquals(listOf(SyncEngine.METADATA_KEY), engine.run(context).downloaded)
        assertTrue(noteStore.isArchived("Work"))
    }

    @Test fun settingsPlistBytesRoundTripUntouched() = runBlocking {
        // Arbitrary binary plist-like bytes, including invalid UTF-8; Android must never reinterpret them.
        val bytes = byteArrayOf(0x62, 0x70, 0x6C, 0x69, 0x73, 0x74, 0x30, 0x30, 0xFF.toByte(), 0x00, 0xD8.toByte(), 0x0A, 0x0D)
        remote.put(SyncEngine.SETTINGS_KEY, bytes)
        engine.run(context)
        assertArrayEquals(bytes, File(root, SyncEngine.SETTINGS_KEY).readBytes())

        // A local replacement (as a desktop would sync down then edit) goes back up byte for byte.
        val edited = bytes + byteArrayOf(0x01, 0x02)
        File(root, SyncEngine.SETTINGS_KEY).writeBytes(edited)
        assertEquals(listOf(SyncEngine.SETTINGS_KEY), engine.run(context).uploaded)
        assertArrayEquals(edited, remote.get(SyncEngine.SETTINGS_KEY).data)
    }

    // MARK: Conflicts

    @Test fun conflictCreation() = runBlocking {
        makeConflict()

        assertEquals("local edit", readLocal("note.md"))
        assertEquals("remote edit", readRemote("note.md"))
        assertEquals("remote edit", SyncState.conflictFile("note.md", root).readText())
        assertEquals(listOf("note.md"), SyncEngine.openConflicts(root, context.identity).map { it.key })
        assertEquals(listOf("note.md"), engine.conflicts.value.map { it.key })

        // The key is skipped until resolved.
        assertEquals(SyncReport(), engine.run(context))
        assertEquals("local edit", readLocal("note.md"))
    }

    @Test fun deleteVersusEditIsConflict() = runBlocking {
        writeLocal("note.md", "base")
        engine.run(context)
        File(root, "note.md").delete()
        putRemote("note.md", "remote edit")

        assertEquals(listOf("note.md"), engine.run(context).newConflicts)
        assertNull("local delete is not undone", readLocal("note.md"))
        assertEquals("remote edit is not deleted", "remote edit", readRemote("note.md"))
    }

    @Test fun resolveKeepLocal() = runBlocking {
        makeConflict()
        engine.resolveConflict("note.md", ConflictResolution.KEEP_LOCAL, context)

        assertEquals("local edit", readRemote("note.md"))
        assertEquals("local edit", readLocal("note.md"))
        assertResolved("note.md")
        assertEquals(SyncReport(), engine.run(context))
    }

    @Test fun resolveKeepRemote() = runBlocking {
        makeConflict()
        engine.resolveConflict("note.md", ConflictResolution.KEEP_REMOTE, context)

        assertEquals("remote edit", readLocal("note.md"))
        assertResolved("note.md")
        assertEquals(SyncReport(), engine.run(context))
    }

    @Test fun resolveKeepBoth() = runBlocking {
        makeConflict()
        engine.resolveConflict("note.md", ConflictResolution.KEEP_BOTH, context)

        assertEquals("local edit", readLocal("note.md"))
        assertEquals("remote edit", readLocal("note (remote).md"))
        assertEquals("local edit", readRemote("note.md"))
        assertEquals("remote edit", readRemote("note (remote).md"))
        assertResolved("note.md")
        assertEquals(SyncReport(), engine.run(context))
    }

    @Test fun keepBothCopyKeepsTheOriginalsDocType() = runBlocking {
        makeConflict()
        noteStore.metadata.setDocType(NoteDocType.CHECKLIST, File(root, "note.md"))
        engine.resolveConflict("note.md", ConflictResolution.KEEP_BOTH, context)

        assertEquals(NoteDocType.CHECKLIST, noteStore.metadata.docType(File(root, "note (remote).md")))
    }

    @Test fun keepBothUniquifiesTakenName() = runBlocking {
        writeLocal("note (remote).md", "already here")
        makeConflict()
        engine.resolveConflict("note.md", ConflictResolution.KEEP_BOTH, context)

        assertEquals("already here", readLocal("note (remote).md"))
        assertEquals("remote edit", readLocal("note (remote 2).md"))
    }

    @Test fun resolveKeepLocalWhenLocalDeletedRemovesRemote() = runBlocking {
        writeLocal("note.md", "base")
        engine.run(context)
        File(root, "note.md").delete()
        putRemote("note.md", "remote edit")
        engine.run(context)

        engine.resolveConflict("note.md", ConflictResolution.KEEP_LOCAL, context)
        assertNull(readRemote("note.md"))
        assertResolved("note.md")
    }

    @Test fun resolvingUnknownKeyThrows() = runBlocking {
        try {
            engine.resolveConflict("nope.md", ConflictResolution.KEEP_LOCAL, context)
            fail("expected NoSuchConflict")
        } catch (e: SyncEngineError) {
            assertEquals(SyncEngineError.NoSuchConflict("nope.md"), e)
        }
    }

    // MARK: First sync and identity

    @Test fun identicalContentFirstSyncIsNoop() = runBlocking {
        writeLocal("same.md", "identical")
        putRemote("same.md", "identical")

        assertEquals(SyncReport(), engine.run(context))
        assertNotNull("base recorded so later edits propagate", state().entries["same.md"])
        assertTrue(state().conflicts.isEmpty())
    }

    @Test fun configIdentityChangeStartsFromEmptyBaseAndDoesNotDelete() = runBlocking {
        writeLocal("keep.md", "precious")
        engine.run(context)

        // Point at a different, empty bucket: the old base must not read as "deleted remotely".
        val other = SyncContext(InMemoryObjectStore(), root, "http://s3.test|other|")
        assertTrue(SyncState.load(root, other.identity).entries.isEmpty())
        val report = engine.run(other)

        assertEquals(listOf("keep.md"), report.uploaded)
        assertTrue(report.deletedLocal.isEmpty())
        assertEquals("precious", readLocal("keep.md"))
    }

    @Test fun stateAndConflictsAreNeverUploaded() = runBlocking {
        writeLocal(SyncEngine.METADATA_KEY, """{"version":1,"notes":{}}""")
        makeConflict()
        writeLocal(".thoughtqueue/conflicts/stray.md", "parked")
        writeLocal("notes.txt", "not a note")
        writeLocal(".hidden/secret.md", "hidden folder")
        writeLocal(".dotnote.md", "hidden file")
        engine.run(context)

        val keys = remote.list("").map { it.key }
        assertTrue("metadata.json syncs", SyncEngine.METADATA_KEY in keys)
        assertFalse(keys.any { it.endsWith(SyncState.FILE_NAME) })
        assertFalse(keys.any { it.contains("conflicts/") })
        assertFalse("notes.txt" in keys)
        assertFalse(keys.any { it.contains(".hidden") || it.contains(".dotnote") })
    }

    @Test fun unsyncableRemoteKeysAreIgnored() = runBlocking {
        putRemote(".thoughtqueue/sync-state.json", "{}")
        putRemote("../escape.md", "nope")
        putRemote("a/./b.md", "nope")
        putRemote("Work//double.md", "nope")
        putRemote("Work/", "folder marker")
        putRemote("image.png", "png")

        assertEquals(SyncReport(), engine.run(context))
        assertFalse(File(root.parentFile, "escape.md").exists())
    }

    @Test fun isSyncedKeyRules() {
        val yes = listOf("a.md", "Work/a.md", "Deep/er/x.MD", "Idées/café ☕.md", SyncEngine.METADATA_KEY, SyncEngine.SETTINGS_KEY)
        val no = listOf("", "md", "a.txt", ".a.md", ".thoughtqueue/sync-state.json", ".thoughtqueue/conflicts/a.md",
            "../a.md", "./a.md", "a//b.md", "/a.md", "a/", ".hidden/a.md")
        yes.forEach { assertTrue(it, SyncEngine.isSyncedKey(it)) }
        no.forEach { assertFalse(it, SyncEngine.isSyncedKey(it)) }
    }

    // MARK: Seeding and triggers

    @Test fun seedCacheMergesWithoutOverwriting() {
        val source = Files.createTempDirectory("tq-seed").toFile()
        try {
            writeLocal("a.md", "from folder", source)
            writeLocal("Work/b.md", "from folder", source)
            writeLocal("a.md", "already cached")

            assertEquals(listOf("Work/b.md"), SyncEngine.seedCache(source, root))
            assertEquals("already cached", readLocal("a.md"))
            assertEquals("from folder", readLocal("Work/b.md"))
        } finally {
            source.deleteRecursively()
        }
    }

    @Test fun syncNowCoalescesRequestsIntoOneFollowUp() = runBlocking {
        writeLocal("a.md", "x")
        val job = engine.syncNow()
        assertNotNull(job)
        assertNull(engine.syncNow())
        assertNull(engine.syncNow())
        withTimeout(5_000) { job!!.join() }

        assertEquals("three requests coalesce into one follow-up run", 2, remote.listCalls)
        assertEquals(SyncStatus.Idle, engine.status.value)
        assertNotNull(engine.lastSyncAt.value)
        assertEquals("x", readRemote("a.md"))
    }

    @Test fun syncNowWithoutConfigReportsError() {
        val unconfigured = SyncEngine(scope, contextProvider = { null })
        assertNull(unconfigured.syncNow())
        assertEquals(SyncStatus.Error(SyncEngineError.NotConfigured.message!!), unconfigured.status.value)
    }

    @Test fun automaticTriggerWithoutConfigIsInert() {
        val unconfigured = SyncEngine(scope, contextProvider = { null })
        assertNull(unconfigured.requestSync(userInitiated = false))
        assertEquals(SyncStatus.Idle, unconfigured.status.value)
    }

    @Test fun failedRunReportsErrorStatus() = runBlocking {
        val failing = object : ObjectStore by remote {
            override suspend fun list(prefix: String): List<RemoteObject> = throw S3ClientError.Http(403)
        }
        val e = SyncEngine(scope, contextProvider = { SyncContext(failing, root, "x") })
        withTimeout(5_000) { e.syncNow()!!.join() }
        assertEquals(SyncStatus.Error("S3 request failed with HTTP 403."), e.status.value)
    }

    @Test fun ownChangeAnnouncementIsNotALocalChange() = runBlocking {
        putRemote("down.md", "from remote")
        engine.run(context)
        val ownVersion = noteStore.changes.value
        assertTrue("the sync's own bump is recognized", engine.isOwnChange(noteStore, ownVersion))

        noteStore.createNote("user note", "typed", null)
        assertFalse("a user edit afterwards is not", engine.isOwnChange(noteStore, noteStore.changes.value))
    }

    @Test fun changeTriggerDebouncesUserEditsButIgnoresSyncWrites() = runBlocking {
        val triggered = SyncEngine(
            scope, contextProvider = { context }, noteStoreProvider = { noteStore },
            syncOnChangeEnabled = { true }, changeDebounceMillis = 50,
        )
        // The sync's own write: announced, then fed back, must not start another run.
        putRemote("down.md", "x")
        triggered.run(context)
        val callsAfterRun = remote.listCalls
        triggered.storeChanged(noteStore, noteStore.changes.value)
        delay(300)
        assertEquals("no self-triggered run", callsAfterRun, remote.listCalls)

        // Three quick user edits debounce into one run.
        repeat(3) {
            noteStore.createNote("n$it", "body", null)
            triggered.storeChanged(noteStore, noteStore.changes.value)
            delay(10)
        }
        withTimeout(5_000) {
            while (remote.listCalls == callsAfterRun || triggered.status.value == SyncStatus.Syncing) delay(20)
        }
        delay(200)
        assertEquals("one debounced run", callsAfterRun + 1, remote.listCalls)
        assertNotNull(readRemote("n0.md"))
    }

    @Test fun changeTriggerRespectsToggle() = runBlocking {
        val off = SyncEngine(scope, contextProvider = { context }, noteStoreProvider = { noteStore },
            syncOnChangeEnabled = { false }, changeDebounceMillis = 20)
        noteStore.createNote("n", "body", null)
        off.storeChanged(noteStore, noteStore.changes.value)
        delay(200)
        assertEquals(0, remote.listCalls)
    }
}
