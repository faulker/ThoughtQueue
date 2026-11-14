package com.thoughtqueue.app.store

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Metadata sidecar behavior, keys, and byte-shape compatibility with the desktop file. */
class NoteMetadataTest {
    private lateinit var root: File
    private lateinit var meta: NoteMetadataStore

    @Before fun setUp() {
        root = Files.createTempDirectory("tq-meta").toFile()
        meta = NoteMetadataStore(root)
    }

    @After fun tearDown() {
        root.deleteRecursively()
    }

    /** A metadata.json exactly as the Swift JSONEncoder (prettyPrinted, sortedKeys) writes it. */
    private val desktopFixture = """{
  "folders" : {
    "Old Stuff" : {
      "archived" : true
    }
  },
  "notes" : {
    "Groceries\/milk.md" : {
      "type" : "checklist"
    },
    "plan.md" : {
      "type" : "markdown"
    }
  },
  "version" : 1
}"""

    @Test fun desktopFileDecodesAndReEncodesToTheSameShape() {
        val decoded = MetadataFile.decode(desktopFixture)
        assertEquals(1, decoded.version)
        assertEquals(NoteDocType.CHECKLIST, decoded.notes["Groceries/milk.md"])
        assertEquals(NoteDocType.MARKDOWN, decoded.notes["plan.md"])
        assertEquals(setOf("Old Stuff"), decoded.archivedFolders)
        assertEquals(desktopFixture, decoded.encode())
    }

    @Test fun desktopFileOnDiskSurvivesAnAndroidWrite() {
        val f = meta.file
        f.parentFile.mkdirs()
        f.writeText(desktopFixture)
        File(root, "Groceries").mkdirs()
        val milk = File(root, "Groceries/milk.md").also { it.writeText("- [ ] a") }
        meta.setDocType(NoteDocType.CHECKLIST, milk) // already recorded: no rewrite needed
        assertEquals(desktopFixture, f.readText())
        val other = File(root, "other.md").also { it.writeText("x") }
        meta.setDocType(NoteDocType.CHECKLIST, other)
        val after = MetadataFile.decode(f.readText())
        assertEquals(NoteDocType.CHECKLIST, after.notes["other.md"])
        assertEquals(NoteDocType.CHECKLIST, after.notes["Groceries/milk.md"])
        assertEquals(setOf("Old Stuff"), after.archivedFolders)
    }

    @Test fun foldersAreOmittedWhenEmptyAndOldFilesWithoutFoldersDecode() {
        val old = MetadataFile.decode("""{"version":1,"notes":{"a.md":{"type":"checklist"}}}""")
        assertTrue(old.archivedFolders.isEmpty())
        assertFalse(old.encode().contains("folders"))
        assertEquals(NoteDocType.CHECKLIST, MetadataFile.decode(old.encode()).notes["a.md"])
    }

    @Test fun unknownKeysAreDroppedAndEmptyEntriesIgnored() {
        val f = MetadataFile.decode("""{"version":1,"notes":{"a.md":{},"b.md":{"type":"markdown","extra":1}},"extra":true}""")
        assertEquals(mapOf("b.md" to NoteDocType.MARKDOWN), f.notes)
    }

    @Test fun malformedFileThrowsAndStoreStartsFresh() {
        meta.file.parentFile.mkdirs()
        meta.file.writeText("not json")
        val note = File(root, "a.md").also { it.writeText("x") }
        assertNull(meta.docType(note))
        meta.setDocType(NoteDocType.CHECKLIST, note)
        assertEquals(NoteDocType.CHECKLIST, meta.docType(note))
    }

    @Test fun keyIsStoreRelative() {
        assertEquals("a.md", NoteMetadataStore.key(File(root, "a.md"), root))
        assertEquals("Cat/a.md", NoteMetadataStore.key(File(root, "Cat/a.md"), root))
    }

    @Test fun keyRejectsPathsOutsideTheRoot() {
        assertNull(NoteMetadataStore.key(File(root.parentFile, "elsewhere.md"), root))
        assertNull(NoteMetadataStore.key(root, root))
    }

    @Test fun keyResolvesSymlinkedRoots() {
        val link = File(root.parentFile, "tq-link-${System.nanoTime()}")
        Files.createSymbolicLink(link.toPath(), root.toPath())
        try {
            assertEquals("Cat/a.md", NoteMetadataStore.key(File(link, "Cat/a.md"), root))
        } finally {
            link.delete()
        }
    }

    @Test fun resolveDefaultsToMarkdown() {
        assertEquals(NoteDocType.MARKDOWN, NoteMetadataStore.resolve(null))
        assertEquals(NoteDocType.CHECKLIST, NoteMetadataStore.resolve(NoteDocType.CHECKLIST))
    }

    @Test fun clearingTheTypeRemovesTheEntry() {
        val note = File(root, "a.md").also { it.writeText("x") }
        meta.setDocType(NoteDocType.CHECKLIST, note)
        meta.setDocType(null, note)
        assertNull(meta.docType(note))
        assertTrue(MetadataFile.decode(meta.file.readText()).notes.isEmpty())
    }

    @Test fun moveFolderRemapsNotesAndArchiveFlag() {
        val a = File(root, "Old/a.md")
        meta.setDocType(NoteDocType.CHECKLIST, a)
        meta.setArchived(true, File(root, "Old"))
        meta.moveFolder(File(root, "Old"), File(root, "New"))
        assertEquals(NoteDocType.CHECKLIST, meta.docType(File(root, "New/a.md")))
        assertTrue(meta.isArchived(File(root, "New")))
        assertNull(meta.docType(a))
        assertFalse(meta.isArchived(File(root, "Old")))
    }

    @Test fun forgetFolderDropsNotesAndFlag() {
        meta.setDocType(NoteDocType.CHECKLIST, File(root, "Gone/a.md"))
        meta.setArchived(true, File(root, "Gone"))
        meta.forgetFolder(File(root, "Gone"))
        assertEquals(MetadataFile.EMPTY.encode(), meta.file.readText())
    }
}
