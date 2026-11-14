package com.thoughtqueue.app.store

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.nio.file.Files

/** Store behavior: creation, naming, metadata remapping, archive visibility, capture. */
class NoteStoreTest {
    private lateinit var root: File
    private lateinit var store: NoteStore

    @Before fun setUp() {
        root = Files.createTempDirectory("tq-store").toFile()
        store = NoteStore(root)
    }

    @After fun tearDown() {
        root.deleteRecursively()
    }

    private fun create(title: String, body: String = "x", cat: String? = null, type: NoteDocType? = null) =
        store.createNote(title, body, cat, type)!!

    // MARK: naming

    @Test fun slugBasicsAndFirstLineOnly() {
        assertEquals("hello-world", NoteStore.slug("Hello World"))
        assertEquals("a-b", NoteStore.slug("a / b!?\nsecond line"))
        assertEquals("", NoteStore.slug("   "))
        assertEquals(60, NoteStore.slug("x".repeat(100)).length)
        assertEquals("café", NoteStore.slug("Café"))
    }

    @Test fun sanitizeCategory() {
        assertNull(NoteStore.sanitizeCategory(".."))
        assertNull(NoteStore.sanitizeCategory("  "))
        assertNull(NoteStore.sanitizeCategory("Uncategorized"))
        assertNull(NoteStore.sanitizeCategory(null))
        assertEquals("a b", NoteStore.sanitizeCategory("a/b"))
        assertEquals("a b", NoteStore.sanitizeCategory("..\\a:b.."))
        assertEquals("x y", NoteStore.sanitizeCategory(" x \n  y "))
    }

    @Test fun sanitizedCategoryStaysInsideRoot() {
        val n = create("n", cat = "../../escape")
        assertTrue(n.file.canonicalPath.startsWith(root.canonicalPath))
        assertEquals("escape", n.category)
    }

    @Test fun uniqueFileNeverOverwrites() {
        val files = (1..5).map { create("same", "body$it").file }
        assertEquals(5, files.toSet().size)
        assertEquals("same-2.md", files[1].name)
        assertEquals("body1", files[0].readText())
    }

    @Test fun createFallsBackToBodyThenTimestamp() {
        assertEquals("first-line-here", create("", "First line here\nmore").title)
        assertTrue(create("", "").title.startsWith("note-"))
    }

    @Test fun createRootAndCategoryNotes() {
        assertNull(create("a").category)
        val b = create("b", cat = "Work")
        assertEquals("Work", b.category)
        assertTrue(File(root, "Work/b.md").isFile)
    }

    // MARK: writes

    @Test fun appendUpdateAndMissingTargets() {
        val n = create("a", "one")
        assertTrue(store.append(n, "two"))
        assertEquals("one\n\ntwo", store.body(n))
        assertTrue(store.updateBody(n, "new"))
        assertEquals("new", store.body(n))
        n.file.delete()
        assertFalse(store.append(n, "x"))
        assertFalse(store.updateBody(n, "x"))
        assertNull(store.rename(n, "z"))
    }

    @Test fun appendToEmptyHasNoSeparator() {
        val n = create("a", "")
        store.append(n, "text")
        assertEquals("text", store.body(n))
    }

    @Test fun cloneKeepsBodyCategoryAndDocType() {
        val n = create("list", "- [ ] a", "Home", NoteDocType.CHECKLIST)
        val c = store.clone(n)!!
        assertEquals("copy-list", c.title)
        assertEquals("Home", c.category)
        assertEquals("- [ ] a", store.body(c))
        assertEquals(NoteDocType.CHECKLIST, store.docType(c))
        assertEquals("copy list", NoteStore.cloneTitle(n))
    }

    @Test fun cloneMissingSourceFails() {
        val n = create("a")
        n.file.delete()
        assertNull(store.clone(n))
    }

    // MARK: doc type and metadata remap

    @Test fun noRecordedTypeIsMarkdownAndContentIsNeverInspected() {
        val n = create("a", "- [ ] x\n- [ ] y")
        assertEquals(NoteDocType.MARKDOWN, store.docType(n))
        store.updateBody(n, "- [ ] a")
        assertEquals(NoteDocType.MARKDOWN, store.docType(n))
    }

    @Test fun docTypeIsWrittenToTheSidecarNotTheNote() {
        val n = create("a", "- [ ] x", type = NoteDocType.CHECKLIST)
        assertEquals("- [ ] x", n.file.readText())
        assertTrue(File(root, ".thoughtqueue/metadata.json").isFile)
        assertTrue(store.categories().isEmpty())
        assertEquals(1, store.allNotes().size)
    }

    @Test fun renameCarriesTheType() {
        val n = create("a", type = NoteDocType.CHECKLIST)
        val r = store.rename(n, "Renamed")!!
        assertEquals("renamed", r.title)
        assertEquals(NoteDocType.CHECKLIST, store.docType(r))
        assertNull(store.metadata.docType(n.file))
    }

    @Test fun moveCarriesTheTypeAndChangesCategory() {
        val n = create("a", type = NoteDocType.CHECKLIST)
        val m = store.move(n, "Work")!!
        assertEquals("Work", m.category)
        assertEquals(NoteDocType.CHECKLIST, store.docType(m))
        assertEquals("Work/a.md", NoteMetadataStore.key(m.file, root))
        val back = store.move(m, null)!!
        assertNull(back.category)
        assertEquals(NoteDocType.CHECKLIST, store.docType(back))
    }

    @Test fun deleteForgetsTheType() {
        val n = create("a", type = NoteDocType.CHECKLIST)
        assertTrue(store.delete(n))
        assertTrue(MetadataFile.decode(File(root, ".thoughtqueue/metadata.json").readText()).notes.isEmpty())
    }

    @Test fun renamingACategoryReKeysItsNotes() {
        val n = create("a", cat = "Old", type = NoteDocType.CHECKLIST)
        assertTrue(store.renameCategory("Old", "New"))
        val moved = store.notes("New").single()
        assertEquals(NoteDocType.CHECKLIST, store.docType(moved))
        assertNull(store.metadata.docType(n.file))
    }

    @Test fun renameCategoryRejectsCollisionAndBadNames() {
        create("a", cat = "A")
        create("b", cat = "B")
        assertFalse(store.renameCategory("A", "B"))
        assertFalse(store.renameCategory("A", ".."))
        assertFalse(store.renameCategory("Missing", "C"))
        assertTrue(store.renameCategory("A", "A"))
    }

    @Test fun deletingACategoryKeepsTheTypeWithTheRelocatedNote() {
        create("a", cat = "Gone", type = NoteDocType.CHECKLIST)
        assertTrue(store.deleteCategory("Gone"))
        val moved = store.notes(null).single()
        assertEquals(NoteDocType.CHECKLIST, store.docType(moved))
        assertFalse(File(root, "Gone").exists())
    }

    @Test fun deleteCategoryAvoidsCollisionsWithRootNotes() {
        create("a", "root")
        create("a", "inner", cat = "Gone")
        assertTrue(store.deleteCategory("Gone"))
        assertEquals(setOf("a", "a-2"), store.notes(null).map { it.title }.toSet())
    }

    // MARK: archive

    @Test fun aFolderNamedArchiveIsVisibleUntilFlagged() {
        create("a", cat = "Archive")
        assertFalse(store.isArchived("Archive"))
        assertEquals(1, store.visibleNotes().size)
    }

    @Test fun archivedFolderNotesStayOnDiskButLeaveVisibleNotes() {
        create("a", cat = "Old")
        create("b")
        assertTrue(store.setArchived(true, "Old"))
        assertEquals(2, store.allNotes().size)
        assertEquals(listOf("b"), store.visibleNotes().map { it.title })
        assertTrue(store.setArchived(false, "Old"))
        assertEquals(2, store.visibleNotes().size)
    }

    @Test fun uncategorizedCannotBeArchived() {
        assertFalse(store.setArchived(true, "Uncategorized"))
        assertFalse(store.isArchived(null))
    }

    @Test fun navigatorCategoriesPutArchivedLast() {
        create("a", cat = "Alpha")
        create("b", cat = "Beta")
        create("c", cat = "Zed")
        store.setArchived(true, "Alpha")
        assertEquals(listOf("Beta", "Zed", null, "Alpha"), store.navigatorCategories())
    }

    @Test fun visibleGroupsOrderCategoriesThenUncategorizedAndSkipArchivedAndEmpty() {
        val older = create("older", cat = "beta")
        older.file.setLastModified(1_000_000)
        create("newer", cat = "beta")
        create("loose")
        create("hidden", cat = "Alpha")
        store.setArchived(true, "Alpha")
        store.createCategory("Empty")
        val groups = store.visibleGroups()
        assertEquals(listOf("beta", null), groups.map { it.first })
        assertEquals(listOf("newer", "older"), groups[0].second.map { it.title })
        assertEquals(listOf("loose"), groups[1].second.map { it.title })
    }

    @Test fun renamingAnArchivedCategoryKeepsTheFlag() {
        create("a", cat = "Old")
        store.setArchived(true, "Old")
        store.renameCategory("Old", "New")
        assertTrue(store.isArchived("New"))
        assertFalse(store.isArchived("Old"))
    }

    @Test fun deletingAnArchivedCategoryDropsTheFlagAndShowsRelocatedNotes() {
        create("a", cat = "Old")
        store.setArchived(true, "Old")
        store.deleteCategory("Old")
        assertEquals(1, store.visibleNotes().size)
        assertTrue(MetadataFile.decode(File(root, ".thoughtqueue/metadata.json").readText()).archivedFolders.isEmpty())
    }

    @Test fun emptyArchivedFolderIsStillListedAndForgottenOnDelete() {
        assertTrue(store.createCategory("Empty"))
        store.setArchived(true, "Empty")
        assertEquals(listOf("Empty"), store.categories())
        store.deleteCategory("Empty")
        assertTrue(store.categories().isEmpty())
    }

    // MARK: listing

    @Test fun hiddenFilesAndFoldersAreNeverNotes() {
        File(root, ".hidden").mkdirs()
        File(root, ".hidden/n.md").writeText("x")
        File(root, ".dot.md").writeText("x")
        File(root, "readme.txt").writeText("x")
        create("real")
        assertEquals(listOf("real"), store.allNotes().map { it.title })
        assertTrue(store.categories().isEmpty())
    }

    @Test fun categoryDerivedFromNestedPath() {
        File(root, "A/B").mkdirs()
        File(root, "A/B/deep.md").writeText("x")
        assertEquals("A", store.allNotes().single().category)
    }

    @Test fun changeSignalIncrementsOnWrites() {
        val before = store.changes.value
        create("a")
        assertTrue(store.changes.value > before)
    }

    // MARK: capture

    @Test fun captureCreatesMarkdownNoteInUncategorized() {
        val result = persistCapture(store, "shared text")
        val note = (result as CaptureResult.Created).note
        assertNull(note.category)
        assertEquals("shared text", store.body(note))
        assertEquals(NoteDocType.MARKDOWN, store.docType(note))
    }

    @Test fun captureAlwaysCreatesANewNote() {
        val existing = create("log", "first")
        assertTrue(persistCapture(store, "second") is CaptureResult.Created)
        assertEquals("first", store.body(existing))
        assertEquals(2, store.allNotes().size)
    }

    @Test fun captureIgnoresBlankText() {
        assertEquals(CaptureResult.Empty, persistCapture(store, "  \n "))
        assertTrue(store.allNotes().isEmpty())
    }

    // MARK: rename decision (regression: opening a mixed-case note must not rename it)

    @Test fun untouchedMixedCaseTitleDoesNotRename() {
        assertFalse(NoteStore.shouldRename("Groceries", "Groceries"))
        assertFalse(NoteStore.shouldRename("  Groceries \n", "Groceries"))
        assertFalse(NoteStore.shouldRename("", "Groceries"))
        assertTrue(NoteStore.shouldRename("Groceries 2", "Groceries"))
        assertTrue(NoteStore.shouldRename("groceries", "Groceries"))
    }

    @Test fun renameSlugsMixedCaseLikeDesktop() {
        val n = create("Seed", cat = "Work Ideas")
        val r = store.rename(n, "My Groceries List")!!
        assertEquals("my-groceries-list", r.title)
        assertEquals("Work Ideas", r.file.parentFile!!.name)
    }

    @Test fun openEditSaveKeepsFilenameIdentical() {
        val dir = File(root, "Work Ideas").apply { mkdirs() }
        File(dir, "Groceries.md").writeText("- [ ] milk\n")
        val note = store.allNotes().single { it.title == "Groceries" }
        assertTrue(store.updateBody(note, "- [x] milk\n"))
        assertEquals(listOf("Groceries.md"), dir.list()!!.toList())
        assertFalse(NoteStore.shouldRename(note.title, note.title))
    }
}
