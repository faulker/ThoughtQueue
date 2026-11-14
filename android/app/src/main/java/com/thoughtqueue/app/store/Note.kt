package com.thoughtqueue.app.store

import java.io.File
import java.nio.file.Files
import java.nio.file.attribute.BasicFileAttributes

/**
 * A note is a value fully derived from its file on disk. Title is the filename without the
 * extension, category is the first subfolder under the store root (null means the file sits in
 * the root, i.e. Uncategorized), and dates come from file attributes. Rebuild it from the file
 * on every read; nothing here is authoritative state.
 */
data class Note(
    val file: File,
    val title: String,
    val category: String?,
    val createdAt: Long,
    val modifiedAt: Long,
) {
    /** Display name for the category, mapping null to "Uncategorized". */
    val categoryDisplay: String get() = category ?: UNCATEGORIZED

    companion object {
        const val UNCATEGORIZED = "Uncategorized"

        /**
         * Build a Note from [file] relative to [storeRoot]. Returns null when the file is not a
         * regular `.md` file under the root, or when any path segment is hidden.
         */
        fun from(file: File, storeRoot: File): Note? {
            if (file.extension.lowercase() != "md") return null
            if (!file.isFile) return null
            val relative = NoteMetadataStore.key(file, storeRoot) ?: return null
            if (relative.split("/").any { it.startsWith(".") }) return null

            val title = file.nameWithoutExtension
            val category = categoryOf(relative)
            val modified = file.lastModified()
            val created = try {
                Files.readAttributes(file.toPath(), BasicFileAttributes::class.java)
                    .creationTime().toMillis()
            } catch (e: java.io.IOException) {
                modified
            }
            return Note(file, title, category, created, modified)
        }

        /**
         * The category for a store-relative path: its first folder, or null for a root-level
         * file. Deeper nesting still uses the first subfolder under the root.
         */
        fun categoryOf(relativePath: String): String? {
            val slash = relativePath.indexOf('/')
            return if (slash < 0) null else relativePath.substring(0, slash)
        }
    }
}
