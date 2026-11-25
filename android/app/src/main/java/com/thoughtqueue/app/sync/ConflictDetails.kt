package com.thoughtqueue.app.sync

import com.thoughtqueue.app.store.Note
import java.io.File
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

/**
 * What the conflicts screen says about one conflict: names, dates and both texts. A null text
 * means that copy was deleted. A port of the desktop's `Sync/ConflictDetails.swift`.
 */
data class ConflictDetails(
    val title: String,
    /** Folder the note is in, or null for the app's own sidecar files. */
    val category: String?,
    val local: String?,
    val remote: String?,
    val localModified: Instant?,
    val remoteModified: Instant?,
) {
    enum class Side { LOCAL, REMOTE }

    /** The more recent side, or null when a copy is gone, a date is unknown, or they match. */
    val newer: Side?
        get() {
            if (local == null || remote == null || localModified == null || remoteModified == null) return null
            val order = localModified.compareTo(remoteModified)
            return if (order > 0) Side.LOCAL else if (order < 0) Side.REMOTE else null
        }

    companion object {
        /** Reads both copies of [conflict]. Throws [java.io.IOException] when one exists but cannot be read. */
        fun load(conflict: SyncState.Conflict, root: File): ConflictDetails {
            val file = SyncEngine.localFile(conflict.key, root)
            val parked = SyncState.conflictFile(conflict.key, root)
            return ConflictDetails(
                title = title(conflict.key),
                category = category(conflict.key),
                local = if (file.exists()) file.readText() else null,
                remote = if (parked.exists()) parked.readText() else null,
                localModified = if (file.exists()) Instant.ofEpochMilli(file.lastModified()) else null,
                remoteModified = conflict.remoteModifiedAt,
            )
        }

        /** A note's title, or a plain name for a sidecar file. */
        fun title(key: String): String = when (key) {
            SyncEngine.METADATA_KEY -> "Note types and archived folders"
            SyncEngine.SETTINGS_KEY -> "App settings"
            else -> key.substringAfterLast('/').substringBeforeLast('.')
        }

        /** The note's folder, "Uncategorized" at the root, or null for a sidecar file. */
        fun category(key: String): String? = when (key) {
            SyncEngine.METADATA_KEY, SyncEngine.SETTINGS_KEY -> null
            else -> key.substringBeforeLast('/', Note.UNCATEGORIZED)
        }

        /** "edited Nov 24, 2026, 9:41 AM, 120 bytes", or "deleted" when that copy is gone. */
        fun sideDescription(verb: String, date: Instant?, text: String?): String {
            if (text == null) return "deleted"
            val whenText = date?.let { "$verb ${formatDate(it)}" } ?: "date unknown"
            val bytes = text.toByteArray().size
            return "$whenText, " + if (bytes < 1024) "$bytes bytes" else "${bytes / 1024} KB"
        }

        /** A date and time in the device's locale and zone. */
        fun formatDate(date: Instant): String =
            DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
                .withZone(ZoneId.systemDefault()).format(date)
    }
}
