package com.thoughtqueue.app.sync

import com.thoughtqueue.app.store.NoteMetadataStore
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.security.MessageDigest
import java.time.Instant
import java.time.format.DateTimeFormatter
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit

/**
 * The sync engine's memory of the last successful sync, stored at
 * [fileOf]. It is device-local, never uploaded and never backed up. A port of the
 * desktop's `Sync/SyncState.swift`, written in the same JSON shape (pretty printed, sorted keys,
 * ISO 8601 dates without fractional seconds).
 *
 * Each entry is the "base" a three-way comparison needs: the local SHA256 and the remote ETag
 * the key had when both sides last agreed. A key with no entry has never been synced, so a
 * missing file on one side is never read as a deletion.
 *
 * The state is scoped to [configIdentity] (endpoint + bucket + prefix). Pointing the app at a
 * different bucket starts from an empty base instead of reading the new bucket's missing keys
 * as deletions.
 */
data class SyncState(
    val configIdentity: String,
    val entries: Map<String, Entry> = emptyMap(),
    val conflicts: List<Conflict> = emptyList(),
) {
    /** What both sides looked like the last time a key was in sync. */
    data class Entry(
        /** Lowercase hex SHA256 of the local file's bytes. */
        val localHash: String,
        /** The remote object's ETag (quotes stripped). */
        val remoteETag: String,
    )

    /** A key both sides changed. It is skipped by sync until the user resolves it. */
    data class Conflict(
        val key: String,
        val detectedAt: Instant,
        /** When the bucket's copy was uploaded, if known. Null when deleted or recorded by an older version. */
        val remoteModifiedAt: Instant? = null,
    )

    /** Whether [key] currently has an open conflict. */
    fun hasConflict(key: String): Boolean = conflicts.any { it.key == key }

    /**
     * Writes the state atomically. The output matches Swift's `JSONEncoder` with `.prettyPrinted`
     * and `.sortedKeys`, so a state file reads the same on either platform.
     */
    fun save(root: File) {
        val file = fileOf(root)
        val dir = file.parentFile!!
        if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create ${dir.path}")
        val tmp = File(dir, "$FILE_NAME.tmp")
        tmp.writeText(encode(), Charsets.UTF_8)
        Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
    }

    /** Encodes the state as Swift would: two-space indent, `"key" : value`, sorted keys, `\/` escaped. */
    fun encode(): String {
        val sb = StringBuilder("{\n")
        sb.append("  \"configIdentity\" : ").append(quote(configIdentity)).append(",\n")
        sb.append("  \"conflicts\" : ")
        if (conflicts.isEmpty()) {
            sb.append("[\n\n  ]")
        } else {
            sb.append("[\n")
            conflicts.forEachIndexed { i, c ->
                sb.append("    {\n")
                sb.append("      \"detectedAt\" : ").append(quote(formatDate(c.detectedAt))).append(",\n")
                sb.append("      \"key\" : ").append(quote(c.key))
                c.remoteModifiedAt?.let { sb.append(",\n      \"remoteModifiedAt\" : ").append(quote(formatDate(it))) }
                sb.append("\n")
                sb.append("    }")
                if (i < conflicts.size - 1) sb.append(",")
                sb.append("\n")
            }
            sb.append("  ]")
        }
        sb.append(",\n  \"entries\" : ")
        if (entries.isEmpty()) {
            sb.append("{\n\n  }")
        } else {
            sb.append("{\n")
            val sorted = entries.toSortedMap()
            var i = 0
            for ((key, entry) in sorted) {
                sb.append("    ").append(quote(key)).append(" : {\n")
                sb.append("      \"localHash\" : ").append(quote(entry.localHash)).append(",\n")
                sb.append("      \"remoteETag\" : ").append(quote(entry.remoteETag)).append("\n")
                sb.append("    }")
                if (i < sorted.size - 1) sb.append(",")
                sb.append("\n")
                i++
            }
            sb.append("  }")
        }
        sb.append("\n}")
        return sb.toString()
    }

    companion object {
        const val FILE_NAME = "sync-state.json"

        /** Folder (beside the state file) holding the remote side of each open conflict. */
        const val CONFLICTS_FOLDER_NAME = "conflicts"

        /** The identity a state file is scoped to: endpoint, bucket and normalized prefix. */
        fun identity(config: S3Config): String =
            "${config.endpoint}|${config.bucket}|${config.normalizedPrefix}"

        /**
         * Folder holding one subfolder of state per notes root. The app points it at
         * `noBackupFilesDir`, so a restored backup cannot carry this device's state to another.
         * Null keeps the state in `<root>/.thoughtqueue/` (unit tests).
         */
        @Volatile var baseDir: File? = null

        /** Where older versions kept the state: `<root>/.thoughtqueue/`. */
        private fun legacyDir(root: File) = File(root, NoteMetadataStore.FOLDER_NAME)

        /** This device's state folder for [root], named by a hash of the root's canonical path. */
        fun directory(root: File): File = baseDir?.let { File(it, hash(root.canonicalPath)) } ?: legacyDir(root)

        /** The state file for [root]. */
        fun fileOf(root: File): File = File(directory(root), FILE_NAME)

        /** Where the remote copy of a conflicted key is parked. */
        fun conflictFile(key: String, root: File): File =
            File(File(directory(root), CONFLICTS_FOLDER_NAME), key)

        /** Lowercase hex SHA256 of [text]. */
        private fun hash(text: String): String = MessageDigest.getInstance("SHA-256")
            .digest(text.toByteArray(Charsets.UTF_8)).joinToString("") { "%02x".format(it) }

        /**
         * Moves state written by older versions out of `<root>/.thoughtqueue/`. Roots are private
         * to the app here, so the old state is always this device's own.
         */
        private fun migrateLegacy(root: File) {
            val target = directory(root)
            val legacy = legacyDir(root)
            val oldState = File(legacy, FILE_NAME)
            if (target == legacy || !oldState.exists() || fileOf(root).exists()) return
            if (!target.isDirectory && !target.mkdirs()) throw IOException("cannot create ${target.path}")
            // Parked copies first: the state file's presence is what marks the migration done.
            val oldConflicts = File(legacy, CONFLICTS_FOLDER_NAME)
            val newConflicts = File(target, CONFLICTS_FOLDER_NAME)
            if (oldConflicts.exists() && !newConflicts.exists()) Files.move(oldConflicts.toPath(), newConflicts.toPath())
            Files.move(oldState.toPath(), fileOf(root).toPath())
        }

        /** A conflict timestamp for now, at the second precision the file stores. */
        fun now(): Instant = Instant.now().truncatedTo(ChronoUnit.SECONDS)

        /**
         * Loads the state for [root]. A missing file, or one written for a different identity,
         * yields a fresh empty state for [identity]. An unreadable file throws rather than being
         * silently replaced, because an empty base would turn every pending delete into a copy.
         */
        fun load(root: File, identity: String): SyncState {
            val state = loadAnyIdentity(root) ?: return SyncState(identity)
            return if (state.configIdentity == identity) state else SyncState(identity)
        }

        /** Reads whatever state file exists regardless of identity, or null when there is none. */
        fun loadAnyIdentity(root: File): SyncState? {
            migrateLegacy(root)
            val file = fileOf(root)
            if (!file.exists()) return null
            return decode(file.readText(Charsets.UTF_8))
        }

        /** Decodes a state file. Throws [IllegalArgumentException] when it is not a valid state document. */
        fun decode(text: String): SyncState {
            try {
                val root = Json.parseToJsonElement(text).jsonObject
                val identity = root["configIdentity"]?.jsonPrimitive?.content
                    ?: throw IllegalArgumentException("sync-state.json has no configIdentity")
                val entries = LinkedHashMap<String, Entry>()
                (root["entries"] as? JsonObject)?.forEach { (key, value) ->
                    val obj = value.jsonObject
                    val hash = obj["localHash"]?.jsonPrimitive?.content
                        ?: throw IllegalArgumentException("entry $key has no localHash")
                    val etag = obj["remoteETag"]?.jsonPrimitive?.content
                        ?: throw IllegalArgumentException("entry $key has no remoteETag")
                    entries[key] = Entry(hash, etag)
                }
                val conflicts = (root["conflicts"] as? JsonArray)?.map { element ->
                    val obj = element.jsonObject
                    val key = obj["key"]?.jsonPrimitive?.content
                        ?: throw IllegalArgumentException("conflict without key")
                    val at = obj["detectedAt"]?.jsonPrimitive?.content
                        ?: throw IllegalArgumentException("conflict $key has no detectedAt")
                    Conflict(key, Instant.parse(at), obj["remoteModifiedAt"]?.jsonPrimitive?.content?.let(Instant::parse))
                } ?: emptyList()
                return SyncState(identity, entries, conflicts)
            } catch (e: IllegalArgumentException) {
                throw e
            } catch (e: DateTimeParseException) {
                throw IllegalArgumentException("sync-state.json has a bad date: ${e.message}", e)
            } catch (e: Exception) {
                throw IllegalArgumentException("sync-state.json is not valid: ${e.message}", e)
            }
        }

        /** ISO 8601 in UTC without fractional seconds, as Swift's `.iso8601` strategy writes. */
        private fun formatDate(instant: Instant): String =
            DateTimeFormatter.ISO_INSTANT.format(instant.truncatedTo(ChronoUnit.SECONDS))

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
}
