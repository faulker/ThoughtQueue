package com.thoughtqueue.app.sync

import com.thoughtqueue.app.store.MetadataFile
import com.thoughtqueue.app.store.NoteDocType
import com.thoughtqueue.app.store.NoteStore
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/**
 * Cross-device fixture: a remote laid out exactly as the desktop writes it (notes in the root and
 * in category folders, `metadata.json` in Swift's pretty-printed shape, an archived folder, a
 * binary-ish `settings.plist`) syncs down into an empty Android store, which must then present
 * it the way the desktop does. Android edits then sync back in a shape the desktop accepts.
 */
class InteropFixtureTest {
    private lateinit var root: File
    private lateinit var remote: InMemoryObjectStore
    private lateinit var store: NoteStore
    private lateinit var scope: CoroutineScope
    private lateinit var engine: SyncEngine
    private lateinit var context: SyncContext

    private val category = "Café Ideas"
    private val checklistKey = "$category/Packing ☕ list.md"

    /** `metadata.json` as the desktop's `JSONEncoder` (`.prettyPrinted`, `.sortedKeys`) writes it. */
    private val desktopMetadata = """
        {
          "folders" : {
            "Old Stuff" : {
              "archived" : true
            }
          },
          "notes" : {
            "Café Ideas\/Packing ☕ list.md" : {
              "type" : "checklist"
            },
            "Welcome.md" : {
              "type" : "markdown"
            }
          },
          "version" : 1
        }
    """.trimIndent()

    /** An XML plist plus trailing bytes that are not valid UTF-8; it must survive byte for byte. */
    private val settingsPlist = (
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict><key>editorFont</key>" +
            "<string>Georgia</string></dict></plist>\n"
        ).toByteArray() + byteArrayOf(0xFE.toByte(), 0x00, 0x81.toByte())

    @Before fun setUp() {
        runBlocking { seed() }
    }

    /** Builds the store, engine and the desktop-shaped remote. */
    private suspend fun seed() {
        root = Files.createTempDirectory("tq-interop").toFile()
        remote = InMemoryObjectStore()
        store = NoteStore(root)
        scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
        context = SyncContext(remote, root, "http://localhost:9000|thoughtqueue|")
        engine = SyncEngine(scope, contextProvider = { context }, noteStoreProvider = { store })

        remote.put("Welcome.md", "# Welcome\n\nWritten on the Mac.\n".toByteArray())
        remote.put(checklistKey, "- [ ] socks\r\n- [x] passport\r\n".toByteArray())
        remote.put("$category/Plain note.md", "- [ ] looks like a list but is markdown\n".toByteArray())
        remote.put("Old Stuff/ancient.md", "archived note".toByteArray())
        remote.put(SyncEngine.METADATA_KEY, desktopMetadata.toByteArray())
        remote.put(SyncEngine.SETTINGS_KEY, settingsPlist)
        // Desktop-local files that must never reach a device even if someone uploaded them.
        remote.put(".thoughtqueue/sync-state.json", "{}".toByteArray())
        remote.put(".thoughtqueue/conflicts/Welcome.md", "parked".toByteArray())
    }

    @After fun tearDown() {
        scope.cancel()
        root.deleteRecursively()
    }

    @Test fun desktopBucketSyncsDownIntact() = runBlocking {
        val report = engine.run(context)
        assertEquals(6, report.downloaded.size)
        assertTrue(report.newConflicts.isEmpty())

        // Categories and notes land where the desktop has them.
        assertEquals(listOf(category, "Old Stuff"), store.categories())
        val all = store.allNotes().associateBy { it.title }
        assertEquals(null, all.getValue("Welcome").category)
        assertEquals(category, all.getValue("Packing ☕ list").category)
        assertEquals(category, all.getValue("Plain note").category)
        assertEquals("Old Stuff", all.getValue("ancient").category)

        // Doc types come from metadata only: the checklist is a checklist, the list-looking note is not.
        assertEquals(NoteDocType.CHECKLIST, store.docType(all.getValue("Packing ☕ list")))
        assertEquals(NoteDocType.MARKDOWN, store.docType(all.getValue("Plain note")))
        assertEquals(NoteDocType.MARKDOWN, store.docType(all.getValue("Welcome")))

        // The archived folder's notes are hidden from the list but still in the store.
        assertTrue(store.isArchived("Old Stuff"))
        assertFalse(store.visibleNotes().any { it.title == "ancient" })
        assertEquals(4, store.allNotes().size)

        // Bytes are untouched: CRLF in the checklist, and the opaque settings plist.
        assertArrayEquals("- [ ] socks\r\n- [x] passport\r\n".toByteArray(), File(root, checklistKey).readBytes())
        assertArrayEquals(settingsPlist, File(root, SyncEngine.SETTINGS_KEY).readBytes())

        // Desktop-local sidecars were not pulled in.
        assertFalse(File(root, ".thoughtqueue/conflicts/Welcome.md").exists())
        assertEquals(6, SyncState.load(root, context.identity).entries.size)
    }

    @Test fun androidEditsSyncBackInDesktopShape() = runBlocking {
        engine.run(context)
        val welcome = store.allNotes().first { it.title == "Welcome" }
        assertTrue(store.updateBody(welcome, "# Welcome\n\nEdited on Android.\n"))
        val plain = store.allNotes().first { it.title == "Plain note" }
        store.setDocType(NoteDocType.CHECKLIST, plain)
        val created = store.createNote("From phone", "hello", category, NoteDocType.MARKDOWN)!!

        val report = engine.run(context)
        assertEquals(
            setOf("Welcome.md", SyncEngine.METADATA_KEY, "$category/${created.file.name}"),
            report.uploaded.toSet(),
        )
        assertEquals("# Welcome\n\nEdited on Android.\n", String(remote.get("Welcome.md").data))

        // The uploaded metadata decodes like the desktop's and keeps the archive flag and old types.
        val uploaded = String(remote.get(SyncEngine.METADATA_KEY).data)
        val decoded = MetadataFile.decode(uploaded)
        assertEquals(NoteDocType.CHECKLIST, decoded.notes["$category/Plain note.md"])
        assertEquals(NoteDocType.CHECKLIST, decoded.notes[checklistKey])
        assertEquals(setOf("Old Stuff"), decoded.archivedFolders)
        assertTrue("Swift-style escaping kept", uploaded.contains("Café Ideas\\/Plain note.md"))

        // settings.plist was never rewritten, so it was never uploaded again.
        assertFalse(SyncEngine.SETTINGS_KEY in report.uploaded)
        assertArrayEquals(settingsPlist, remote.get(SyncEngine.SETTINGS_KEY).data)
    }
}
