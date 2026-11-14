package com.thoughtqueue.app.store

import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.updateAndGet
import java.io.File
import java.io.IOException
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.UUID
import java.util.logging.Logger

/** Where the working document's store-relative path is remembered (preferences in the app, memory in tests). */
interface WorkingDocumentRef {
    var relativePath: String?
}

/** A [WorkingDocumentRef] that only lives in memory. */
class InMemoryWorkingDocument(override var relativePath: String? = null) : WorkingDocumentRef

/**
 * Filesystem-backed note store. The store folder is the single source of truth: notes are plain
 * `.md` files, categories are immediate subfolders, dates are file attributes. Document type and
 * archive flags live in the metadata sidecar ([NoteMetadataStore]).
 *
 * [changes] is the `.notesDidChange` equivalent: a counter that increments after every write, so
 * UI can re-query by collecting it.
 */
class NoteStore(
    root: File,
    private val workingDocument: WorkingDocumentRef = InMemoryWorkingDocument(),
) {
    val root: File = root.absoluteFile
    val metadata = NoteMetadataStore(this.root)
    private val log = Logger.getLogger("NoteStore")

    private val version = MutableStateFlow(0)

    /** Increments whenever notes or their metadata change. */
    val changes: StateFlow<Int> = version.asStateFlow()

    init {
        if (!this.root.isDirectory && !this.root.mkdirs()) {
            log.severe("cannot create store root ${this.root.path}")
        }
    }

    /**
     * Announce a change and return the new [changes] value. Sync uses the returned value to
     * recognize its own announcement so it does not trigger itself.
     */
    fun postChange(): Int = version.updateAndGet { it + 1 }

    // MARK: Working document

    /** The note designated as the working document, or null when unset or its file is gone. */
    fun workingDocumentNote(): Note? {
        val rel = workingDocument.relativePath ?: return null
        val file = File(root, rel)
        if (!file.exists()) return null
        return Note.from(file, root)
    }

    /** Store-relative path of the working document, even if its file is missing. */
    val workingDocumentPath: String? get() = workingDocument.relativePath

    /** Designate [note] as the working document, or clear it with null. */
    fun setWorkingDocument(note: Note?) {
        workingDocument.relativePath = note?.let { NoteMetadataStore.key(it.file, root) }
        postChange()
    }

    /** Clear a stale working document setting without announcing a note change. */
    fun clearWorkingDocument() {
        workingDocument.relativePath = null
    }

    // MARK: Reads

    /**
     * Category names for the navigator: active folders, then Uncategorized (null), then archived.
     * Null can be passed straight to [notes].
     */
    fun navigatorCategories(): List<String?> {
        val names = categories()
        return names.filter { !isArchived(it) } + listOf(null) + names.filter { isArchived(it) }
    }

    /** All category names (immediate non-hidden subfolders), sorted. Excludes Uncategorized. */
    fun categories(): List<String> {
        val entries = root.listFiles() ?: return emptyList()
        return entries
            .filter { it.isDirectory && !it.name.startsWith(".") }
            .map { it.name }
            .sortedWith(String.CASE_INSENSITIVE_ORDER)
    }

    /** All notes across the store, newest first by modified date. Includes archived folders. */
    fun allNotes(): List<Note> {
        val result = ArrayList<Note>()
        collectNotes(root, result)
        return result.sortedByDescending { it.modifiedAt }
    }

    /** Notes the list shows: everything except those in archived folders. */
    fun visibleNotes(): List<Note> = allNotes().filter { !isArchived(it.category) }

    /** Notes in a category. Pass null for Uncategorized (root-level notes only). */
    fun notes(category: String?): List<Note> = allNotes().filter { it.category == category }

    /** Whether [category] is flagged archived. Null (Uncategorized) is never archived. */
    fun isArchived(category: String?): Boolean {
        if (category == null) return false
        val safe = sanitizeCategory(category) ?: return false
        return metadata.isArchived(File(root, safe))
    }

    /** Record (or clear) the archive flag on a category folder. Returns false for a bad name. */
    fun setArchived(archived: Boolean, category: String): Boolean {
        val safe = sanitizeCategory(category) ?: return false
        if (isArchived(category) == archived) return true
        metadata.setArchived(archived, File(root, safe))
        postChange()
        return true
    }

    /** Recursively collect notes, skipping hidden files and folders. */
    private fun collectNotes(dir: File, result: MutableList<Note>) {
        val entries = dir.listFiles() ?: return
        for (entry in entries) {
            if (entry.name.startsWith(".")) continue
            if (entry.isDirectory) collectNotes(entry, result)
            else Note.from(entry, root)?.let { result.add(it) }
        }
    }

    /** Read the full markdown body of a note; empty when unreadable. */
    fun body(note: Note): String = try {
        note.file.readText(Charsets.UTF_8)
    } catch (e: IOException) {
        log.warning("read failed for ${note.file.path}: ${e.message}")
        ""
    }

    // MARK: Naming

    companion object {
        /** Characters Swift's `isDefaultIgnorableCodePoint` would drop, approximated. */
        private fun isIgnorable(cp: Int): Boolean =
            Character.getType(cp) == Character.FORMAT.toInt() ||
                cp in 0x200B..0x200F || cp in 0x2060..0x206F || cp in 0xFE00..0xFE0F ||
                cp == 0xFEFF || cp == 0x00AD || cp == 0x034F || cp in 0x180B..0x180E ||
                cp in 0xE0000..0xE0FFF

        private fun isNewline(c: Char) = c == '\n' || c == '\r' || c == '\u0085' || c == ' ' || c == ' '

        /**
         * Sanitize a category name so it can never escape the store root. Strips path
         * separators and control characters, collapses whitespace, trims dots and spaces.
         * Returns null when it normalizes to empty (the caller treats null as Uncategorized).
         */
        fun sanitizeCategory(raw: String?): String? {
            if (raw == null) return null
            var name = raw.trim()
            if (name.isEmpty() || name == Note.UNCATEGORIZED) return null

            name = name.replace('/', ' ').replace('\\', ' ').replace(':', ' ')
            val sb = StringBuilder()
            name.codePoints().filter { !isIgnorable(it) && it >= 0x20 }.forEach { sb.appendCodePoint(it) }
            name = sb.toString()

            name = name.split(' ').flatMap { part ->
                part.split('\n', '\r', '\u0085', ' ', ' ')
            }.filter { it.isNotEmpty() }.joinToString(" ")

            name = name.trim { it == '.' || it == ' ' }
            if (name.isEmpty() || name == "." || name == "..") return null
            return name
        }

        /**
         * Slugify a string into a safe filename stem (no extension): first line only, lowercase,
         * words joined by hyphens, path-unsafe characters dropped, capped at 60 characters.
         */
        fun slug(raw: String): String {
            val trimmed = raw.trim()
            if (trimmed.isEmpty()) return ""
            val firstLine = trimmed.split('\n', '\r', '\u0085', ' ', ' ')
                .firstOrNull { it.isNotEmpty() } ?: trimmed

            val filtered = StringBuilder()
            firstLine.codePoints().forEach { cp ->
                val type = Character.getType(cp)
                val mark = type == Character.NON_SPACING_MARK.toInt() ||
                    type == Character.COMBINING_SPACING_MARK.toInt() ||
                    type == Character.ENCLOSING_MARK.toInt()
                if (Character.isLetterOrDigit(cp) || mark || cp == ' '.code || cp == '-'.code || cp == '_'.code) {
                    filtered.appendCodePoint(cp)
                }
            }
            val collapsed = filtered.toString().lowercase()
                .split(' ', '-').filter { it.isNotEmpty() }.joinToString("-")
            return collapsed.take(60).trim('-')
        }

        /**
         * Whether typed title [typed] warrants a rename of a note currently titled [current].
         * Mirrors the desktop: raw trimmed text compared against the title, never its slug, so an
         * untouched mixed-case title (or the initial focus callback) can never rename the file.
         */
        fun shouldRename(typed: String, current: String): Boolean {
            val t = typed.trim()
            return t.isNotEmpty() && t != current
        }

        /** A timestamp-based filename stem, used when no title is available. */
        fun timestampStem(): String =
            "note-" + SimpleDateFormat("yyyy-MM-dd-HHmmss", Locale.US).format(Date())

        /** Title used when cloning a note: parent title with "copy" prefixed. */
        fun cloneTitle(note: Note): String = "copy ${note.title}"
    }

    /**
     * Resolve a non-colliding file for [stem] inside [folder]. If `<stem>.md` exists, a numeric
     * counter is appended, then a UUID fragment as a last resort, so nothing is ever overwritten.
     */
    fun uniqueFile(stem: String, folder: File): File {
        val base = stem.ifEmpty { timestampStem() }
        var candidate = File(folder, "$base.md")
        if (!candidate.exists()) return candidate
        for (counter in 2..999) {
            candidate = File(folder, "$base-$counter.md")
            if (!candidate.exists()) return candidate
        }
        repeat(5) {
            val unique = File(folder, "$base-${UUID.randomUUID().toString().take(8)}.md")
            if (!unique.exists()) return unique
        }
        return File(folder, "$base-${UUID.randomUUID()}.md")
    }

    // MARK: Writes

    /** Folder for a category, created on demand; null or unsanitary names mean the root. */
    private fun folderFor(category: String?): File {
        val safe = sanitizeCategory(category) ?: return root
        val folder = File(root, safe)
        if (!folder.isDirectory) folder.mkdirs()
        return folder
    }

    /**
     * Create a note. [title] becomes the filename (slugified); empty falls back to the first body
     * line, then a timestamp. [docType] is recorded in metadata when non-null. Returns null on failure.
     */
    fun createNote(title: String, body: String, category: String?, docType: NoteDocType? = null): Note? {
        val folder = folderFor(category)
        var stem = slug(title)
        if (stem.isEmpty()) stem = slug(body)
        val file = uniqueFile(stem, folder)
        try {
            file.writeText(body, Charsets.UTF_8)
        } catch (e: IOException) {
            log.severe("createNote write failed: ${e.message}")
            return null
        }
        if (docType != null) metadata.setDocType(docType, file)
        val note = Note.from(file, root)
        postChange()
        return note
    }

    // MARK: Document type

    /** How [note] is presented: its recorded type, or markdown when nothing is recorded. */
    fun docType(note: Note): NoteDocType = NoteMetadataStore.resolve(metadata.docType(note.file))

    /** Record [note]'s document type so the choice survives edits and restarts. */
    fun setDocType(type: NoteDocType?, note: Note) {
        metadata.setDocType(type, note.file)
        postChange()
    }

    /** Duplicate a note into the same category titled `copy <title>`, keeping body and doc type. */
    fun clone(note: Note): Note? {
        if (!note.file.exists()) {
            log.warning("clone source missing: ${note.file.path}")
            return null
        }
        return createNote(cloneTitle(note), body(note), note.category, metadata.docType(note.file))
    }

    /** Append [text] to a note, separated by a blank line. Returns true on success. */
    fun append(note: Note, text: String): Boolean {
        if (!note.file.exists()) {
            log.warning("append target missing: ${note.file.path}")
            return false
        }
        val existing = body(note)
        val separator = if (existing.isEmpty()) "" else "\n\n"
        return try {
            note.file.writeText(existing + separator + text, Charsets.UTF_8)
            postChange()
            true
        } catch (e: IOException) {
            log.severe("append write failed: ${e.message}")
            false
        }
    }

    /** Overwrite a note's body. Aborts when the file vanished, so a stale path is never recreated. */
    fun updateBody(note: Note, body: String): Boolean {
        if (!note.file.exists()) {
            log.warning("updateBody target missing, aborting: ${note.file.path}")
            return false
        }
        return try {
            note.file.writeText(body, Charsets.UTF_8)
            postChange()
            true
        } catch (e: IOException) {
            log.severe("updateBody failed: ${e.message}")
            false
        }
    }

    /** Rename a note's title (its filename). Returns the new Note or null on failure. */
    fun rename(note: Note, newTitle: String): Note? {
        if (!note.file.exists()) {
            log.warning("rename source missing, aborting: ${note.file.path}")
            return null
        }
        var stem = slug(newTitle)
        if (stem.isEmpty()) stem = timestampStem()
        val dest = uniqueFile(stem, note.file.parentFile!!)
        return relocate(note, dest, "rename")
    }

    /** Move a note to another category; null means Uncategorized. */
    fun move(note: Note, category: String?): Note? {
        if (!note.file.exists()) {
            log.warning("move source missing, aborting: ${note.file.path}")
            return null
        }
        val folder = folderFor(category)
        val dest = uniqueFile(note.file.nameWithoutExtension, folder)
        return relocate(note, dest, "move")
    }

    /** Move the note file to [dest], carrying its metadata entry across. */
    private fun relocate(note: Note, dest: File, what: String): Note? {
        try {
            java.nio.file.Files.move(note.file.toPath(), dest.toPath())
        } catch (e: IOException) {
            log.severe("$what failed: ${e.message}")
            return null
        }
        metadata.move(note.file, dest)
        val result = Note.from(dest, root)
        postChange()
        return result
    }

    /** Delete a note and its metadata entry. */
    fun delete(note: Note): Boolean {
        if (!note.file.delete()) {
            log.severe("delete failed: ${note.file.path}")
            return false
        }
        metadata.forget(note.file)
        postChange()
        return true
    }

    /** Create a category folder. Rejects names that sanitize away. True if created or present. */
    fun createCategory(name: String): Boolean {
        val safe = sanitizeCategory(name) ?: return false
        val ok = folderFor(safe).isDirectory
        if (ok) postChange()
        return ok
    }

    /**
     * Rename a category folder. Fails when either name sanitizes away, the source is missing or
     * the destination exists. Remaps metadata keys and the working document when it lived under it.
     */
    fun renameCategory(oldName: String, newName: String): Boolean {
        val oldSafe = sanitizeCategory(oldName) ?: return false
        val newSafe = sanitizeCategory(newName) ?: return false
        if (oldSafe == newSafe) return true
        val oldFolder = File(root, oldSafe)
        val newFolder = File(root, newSafe)
        if (!oldFolder.exists()) {
            log.warning("renameCategory source missing: ${oldFolder.path}")
            return false
        }
        if (newFolder.exists()) {
            log.warning("renameCategory destination exists: ${newFolder.path}")
            return false
        }
        try {
            java.nio.file.Files.move(oldFolder.toPath(), newFolder.toPath())
        } catch (e: IOException) {
            log.severe("renameCategory failed: ${e.message}")
            return false
        }
        metadata.moveFolder(oldFolder, newFolder)
        workingDocument.relativePath?.let { rel ->
            if (rel == oldSafe || rel.startsWith("$oldSafe/")) {
                workingDocument.relativePath = newSafe + rel.substring(oldSafe.length)
            }
        }
        postChange()
        return true
    }

    /**
     * Delete a category folder. Its notes move to Uncategorized first so nothing is lost; the
     * folder is then removed along with its metadata. The working document follows a moved note.
     */
    fun deleteCategory(name: String): Boolean {
        val safe = sanitizeCategory(name) ?: return false
        val folder = File(root, safe)
        if (!folder.isDirectory) {
            log.warning("deleteCategory missing: ${folder.path}")
            return false
        }
        for (note in notes(safe)) {
            val dest = uniqueFile(note.file.nameWithoutExtension, root)
            val oldKey = NoteMetadataStore.key(note.file, root)
            try {
                java.nio.file.Files.move(note.file.toPath(), dest.toPath())
            } catch (e: IOException) {
                log.severe("deleteCategory move failed: ${e.message}")
                postChange()
                return false
            }
            metadata.move(note.file, dest)
            if (oldKey != null && workingDocument.relativePath == oldKey) {
                workingDocument.relativePath = NoteMetadataStore.key(dest, root)
            }
        }
        if (!folder.deleteRecursively()) {
            log.severe("deleteCategory remove failed: ${folder.path}")
            postChange()
            return false
        }
        metadata.forgetFolder(folder)
        postChange()
        return true
    }
}
