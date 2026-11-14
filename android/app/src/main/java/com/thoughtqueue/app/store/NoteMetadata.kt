package com.thoughtqueue.app.store

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.io.IOException
import java.util.logging.Logger

/** How a note is presented. Recorded explicitly in metadata, never guessed from content. */
enum class NoteDocType(val raw: String) {
    /** An ordinary markdown document, even if it happens to contain task lines. */
    MARKDOWN("markdown"),

    /** A checkbox list, presented by the checklist screen. */
    CHECKLIST("checklist");

    companion object {
        /** The type for a raw JSON string, or null when it is not a known type. */
        fun fromRaw(raw: String): NoteDocType? = entries.firstOrNull { it.raw == raw }
    }
}

/**
 * The on-disk shape of `.thoughtqueue/metadata.json`, byte-compatible with the desktop app's
 * Swift `Codable` file: `version`, `notes{relpath:{type}}` and `folders{name:{archived}}`.
 * `folders` is omitted from the output when empty, and an empty entry is never stored.
 */
data class MetadataFile(
    val version: Int = CURRENT_VERSION,
    val notes: Map<String, NoteDocType> = emptyMap(),
    val archivedFolders: Set<String> = emptySet(),
) {
    companion object {
        const val CURRENT_VERSION = 1
        val EMPTY = MetadataFile()

        /**
         * Decode a metadata file. `notes` and `folders` may be absent. Throws
         * [IllegalArgumentException] on malformed JSON or an unknown document type, which is
         * what the desktop's strict decoder does too.
         */
        fun decode(text: String): MetadataFile {
            val root = try {
                Json.parseToJsonElement(text).jsonObject
            } catch (e: Exception) {
                throw IllegalArgumentException("metadata.json is not a JSON object: ${e.message}")
            }
            val version = root["version"]?.jsonPrimitive?.int
                ?: throw IllegalArgumentException("metadata.json has no version")
            val notes = LinkedHashMap<String, NoteDocType>()
            (root["notes"] as? JsonObject)?.forEach { (key, value) ->
                val typeEl = value.jsonObject["type"] ?: return@forEach
                val raw = typeEl.jsonPrimitive.content
                notes[key] = NoteDocType.fromRaw(raw)
                    ?: throw IllegalArgumentException("unknown document type \"$raw\"")
            }
            val archived = LinkedHashSet<String>()
            (root["folders"] as? JsonObject)?.forEach { (key, value) ->
                val flag = value.jsonObject["archived"]?.jsonPrimitive
                if (flag?.booleanOrNull == true) archived.add(key)
            }
            return MetadataFile(version, notes, archived)
        }
    }

    /**
     * Encode like Swift's `JSONEncoder` with `.prettyPrinted` and `.sortedKeys`: two-space
     * indent, `"key" : value`, sorted keys, `/` escaped as `\/`, and `folders` omitted when empty.
     */
    fun encode(): String {
        val sb = StringBuilder()
        sb.append("{\n")
        if (archivedFolders.isNotEmpty()) {
            sb.append("  \"folders\" : ")
            appendObject(sb, 1, archivedFolders.sorted().map { it to "{\n      \"archived\" : true\n    }" })
            sb.append(",\n")
        }
        sb.append("  \"notes\" : ")
        appendObject(sb, 1, notes.toSortedMap().map { (k, v) ->
            k to "{\n      \"type\" : \"${v.raw}\"\n    }"
        })
        sb.append(",\n  \"version\" : ").append(version).append("\n}")
        return sb.toString()
    }

    private fun appendObject(sb: StringBuilder, depth: Int, entries: List<Pair<String, String>>) {
        val pad = "  ".repeat(depth + 1)
        if (entries.isEmpty()) {
            sb.append("{\n\n").append("  ".repeat(depth)).append("}")
            return
        }
        sb.append("{\n")
        entries.forEachIndexed { i, (key, value) ->
            sb.append(pad).append(quote(key)).append(" : ").append(value)
            if (i < entries.size - 1) sb.append(",")
            sb.append("\n")
        }
        sb.append("  ".repeat(depth)).append("}")
    }

    /** JSON-quote a string the way Foundation does, including the `\/` escape. */
    private fun quote(s: String): String {
        val sb = StringBuilder("\"")
        for (c in s) {
            when {
                c == '"' -> sb.append("\\\"")
                c == '\\' -> sb.append("\\\\")
                c == '/' -> sb.append("\\/")
                c == '\n' -> sb.append("\\n")
                c == '\r' -> sb.append("\\r")
                c == '\t' -> sb.append("\\t")
                c == '\b' -> sb.append("\\b")
                c == '\u000C' -> sb.append("\\f")
                c < ' ' -> sb.append("\\u%04x".format(c.code))
                else -> sb.append(c)
            }
        }
        return sb.append('"').toString()
    }
}

/**
 * Explicit per-note and per-folder metadata for a store folder, kept in one sidecar,
 * `.thoughtqueue/metadata.json`. Notes stay plain markdown: nothing here touches note bytes.
 *
 * Content is never consulted. A note with no recorded type is a markdown document. A folder is
 * archived only when flagged. Keys are store-relative paths (`Cat/note.md`, `Cat`), so the file
 * survives moving the store, and the app's own renames, moves and deletes remap or drop keys.
 *
 * The file is re-read on every access so a sync that replaces it is picked up without any
 * cache invalidation. Writes are atomic (temp file then rename).
 */
class NoteMetadataStore(root: File) {
    private val root: File = root.absoluteFile
    private val log = Logger.getLogger("NoteMetadataStore")

    /** The metadata file inside the store folder. */
    val file: File get() = File(File(root, FOLDER_NAME), FILE_NAME)

    companion object {
        const val FOLDER_NAME = ".thoughtqueue"
        const val FILE_NAME = "metadata.json"

        /**
         * Store-relative key for [file], or null when it does not live under [root]. Both sides
         * resolve symlinks first (Android's `/data/user/0` is a symlink to `/data/data`), and a
         * path that no longer exists still resolves, which matters because keys are computed for
         * files that have just moved.
         */
        fun key(file: File, root: File): String? {
            val rootPath = canonical(root)
            val path = canonical(file)
            if (!path.startsWith("$rootPath/")) return null
            val relative = path.substring(rootPath.length + 1)
            return relative.ifEmpty { null }
        }

        private fun canonical(f: File): String = try {
            f.canonicalPath
        } catch (e: IOException) {
            f.absoluteFile.normalize().path
        }

        /** The type to present a note as: its recorded type, or markdown when none is recorded. */
        fun resolve(explicit: NoteDocType?): NoteDocType = explicit ?: NoteDocType.MARKDOWN
    }

    // MARK: Reads

    /** The recorded type for [note], or null when nothing was recorded. */
    @Synchronized
    fun docType(note: File): NoteDocType? = key(note, root)?.let { load().notes[it] }

    /** Whether [folder] is flagged archived. Unknown folders are visible. */
    @Synchronized
    fun isArchived(folder: File): Boolean = key(folder, root)?.let { it in load().archivedFolders } ?: false

    // MARK: Writes

    /** Record (or, with null, clear) the type for a note file. */
    fun setDocType(type: NoteDocType?, note: File) = mutate { f ->
        val k = key(note, root) ?: return@mutate null
        if (f.notes[k] == type) return@mutate null
        f.copy(notes = if (type == null) f.notes - k else f.notes + (k to type))
    }

    /** Flag (or, with false, clear) a category folder as archived. */
    fun setArchived(archived: Boolean, folder: File) = mutate { f ->
        val k = key(folder, root) ?: return@mutate null
        if ((k in f.archivedFolders) == archived) return@mutate null
        f.copy(archivedFolders = if (archived) f.archivedFolders + k else f.archivedFolders - k)
    }

    /** Carry a note's entry across a rename or a move to another category. */
    fun move(oldFile: File, newFile: File) = mutate { f ->
        val oldKey = key(oldFile, root) ?: return@mutate null
        val newKey = key(newFile, root) ?: return@mutate null
        if (oldKey == newKey) return@mutate null
        val type = f.notes[oldKey] ?: return@mutate null
        f.copy(notes = f.notes - oldKey + (newKey to type))
    }

    /** Drop a deleted note's entry so the file does not accumulate ghosts. */
    fun forget(note: File) = mutate { f ->
        val k = key(note, root) ?: return@mutate null
        if (k !in f.notes) null else f.copy(notes = f.notes - k)
    }

    /** Re-key every entry under [oldFolder] to sit under [newFolder], including its archive flag. */
    fun moveFolder(oldFolder: File, newFolder: File) = mutate { f ->
        val oldPrefix = key(oldFolder, root) ?: return@mutate null
        val newPrefix = key(newFolder, root) ?: return@mutate null
        if (oldPrefix == newPrefix) return@mutate null
        var changed = false
        val notes = LinkedHashMap<String, NoteDocType>()
        for ((k, v) in f.notes) {
            if (k.startsWith("$oldPrefix/")) {
                notes[newPrefix + k.substring(oldPrefix.length)] = v
                changed = true
            } else {
                notes[k] = v
            }
        }
        var archived = f.archivedFolders
        if (oldPrefix in archived) {
            archived = archived - oldPrefix + newPrefix
            changed = true
        }
        if (changed) f.copy(notes = notes, archivedFolders = archived) else null
    }

    /** Forget everything under a folder, including its own archive flag. */
    fun forgetFolder(folder: File) = mutate { f ->
        val prefix = key(folder, root) ?: return@mutate null
        val notes = f.notes.filterKeys { !it.startsWith("$prefix/") }
        val archived = f.archivedFolders - prefix
        if (notes.size == f.notes.size && archived.size == f.archivedFolders.size) null
        else f.copy(notes = notes, archivedFolders = archived)
    }

    // MARK: Persistence

    /** Apply [change] to the loaded file and write the result when it reported an edit (non-null). */
    @Synchronized
    private fun mutate(change: (MetadataFile) -> MetadataFile?) {
        val updated = change(load()) ?: return
        try {
            save(updated)
        } catch (e: IOException) {
            log.severe("metadata write failed: ${e.message}")
        }
    }

    /**
     * Read the file. A missing file is empty; an unreadable one is logged and treated as empty,
     * as the desktop does.
     */
    private fun load(): MetadataFile {
        val f = file
        if (!f.isFile) return MetadataFile.EMPTY
        return try {
            MetadataFile.decode(f.readText(Charsets.UTF_8))
        } catch (e: IllegalArgumentException) {
            log.severe("metadata.json unreadable; starting fresh: ${e.message}")
            MetadataFile.EMPTY
        } catch (e: IOException) {
            log.severe("metadata.json read failed; starting fresh: ${e.message}")
            MetadataFile.EMPTY
        }
    }

    /** Write atomically through a temp file in the same folder. Throws on failure. */
    private fun save(data: MetadataFile) {
        val f = file
        val dir = f.parentFile!!
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create ${dir.path}")
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(data.encode(), Charsets.UTF_8)
        java.nio.file.Files.move(
            tmp.toPath(), f.toPath(),
            java.nio.file.StandardCopyOption.REPLACE_EXISTING,
            java.nio.file.StandardCopyOption.ATOMIC_MOVE,
        )
    }
}
