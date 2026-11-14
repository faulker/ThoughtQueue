package com.thoughtqueue.app.sync

import com.thoughtqueue.app.store.NoteMetadataStore
import com.thoughtqueue.app.store.NoteStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.time.Instant
import java.util.logging.Logger

/** What the engine is doing right now. */
sealed class SyncStatus {
    data object Idle : SyncStatus()
    data object Syncing : SyncStatus()
    data class Error(val message: String) : SyncStatus()
}

/** How the user chose to settle a conflict. */
enum class ConflictResolution {
    /** Local wins: upload it (or delete the remote if local is gone). */
    KEEP_LOCAL,

    /** Remote wins: write it locally (or delete local if remote is gone). */
    KEEP_REMOTE,

    /** Keep both: the remote copy is saved beside the note as "Name (remote).md". */
    KEEP_BOTH,
}

/** Engine-level failures, with user-readable messages matching the desktop's. */
sealed class SyncEngineError(message: String) : Exception(message) {
    data object NotConfigured :
        SyncEngineError("S3 sync is not configured (mode, endpoint, bucket, access key or secret missing).")

    data class NoSuchConflict(val key: String) : SyncEngineError("There is no open sync conflict for $key.")

    data class InvalidKey(val key: String) : SyncEngineError("$key is not a syncable path.")
}

/**
 * Everything one sync run needs. Injected so tests can run against an in-memory store and a
 * temp folder without touching preferences or the secret store.
 */
data class SyncContext(
    val store: ObjectStore,
    val root: File,
    /** [SyncState.identity] of the S3 config, scoping the base state. */
    val identity: String,
)

/** What a run or resolution changed, by key. */
data class SyncReport(
    val uploaded: MutableList<String> = mutableListOf(),
    val downloaded: MutableList<String> = mutableListOf(),
    val deletedLocal: MutableList<String> = mutableListOf(),
    val deletedRemote: MutableList<String> = mutableListOf(),
    val newConflicts: MutableList<String> = mutableListOf(),
) {
    /** Whether any file under the root was written or removed. */
    val changedLocalFiles: Boolean get() = downloaded.isNotEmpty() || deletedLocal.isNotEmpty()
}

/**
 * Bi-directional sync between the store root and an [ObjectStore]. A port of the desktop's
 * `Sync/SyncEngine.swift`.
 *
 * Runs and conflict resolutions are serialized through a [Mutex] and do their work on
 * [Dispatchers.IO]. Triggered runs coalesce: a trigger while a run is going schedules exactly
 * one follow-up. Conflicts are never resolved automatically; the remote side is parked in
 * `.thoughtqueue/conflicts/<key>` and the key is skipped until [resolveConflict] is called.
 *
 * The engine has no Android dependencies. The app supplies [contextProvider] (preferences plus
 * the secret store), [noteStoreProvider] (the active store, whose change signal is bumped after
 * a sync writes files) and [syncOnChangeEnabled].
 */
class SyncEngine(
    private val scope: CoroutineScope,
    private val contextProvider: () -> SyncContext?,
    private val noteStoreProvider: () -> NoteStore? = { null },
    private val syncOnChangeEnabled: () -> Boolean = { false },
    private val changeDebounceMillis: Long = CHANGE_DEBOUNCE_MS,
) {
    private val log = Logger.getLogger("SyncEngine")

    private val _status = MutableStateFlow<SyncStatus>(SyncStatus.Idle)
    private val _lastSyncAt = MutableStateFlow<Instant?>(null)
    private val _conflicts = MutableStateFlow<List<SyncState.Conflict>>(emptyList())

    /** Current engine status; an error carries a user-readable message. */
    val status: StateFlow<SyncStatus> = _status.asStateFlow()

    /** When the last triggered run finished successfully, or null. */
    val lastSyncAt: StateFlow<Instant?> = _lastSyncAt.asStateFlow()

    /** Open conflicts for the last synced (or refreshed) root, oldest first. */
    val conflicts: StateFlow<List<SyncState.Conflict>> = _conflicts.asStateFlow()

    private val mutex = Mutex()
    private val lock = Any()
    private var isSyncing = false
    private var rerunRequested = false
    private var debounceJob: Job? = null

    /** The store and version of the engine's own last change announcement. */
    @Volatile
    private var ownChange: Pair<NoteStore, Int>? = null

    // MARK: Triggers

    /**
     * Runs a sync now. Unlike automatic triggers, a missing configuration is reported as an
     * error status. Returns the run's job, or null when none started (already running, which
     * schedules a follow-up, or not configured).
     */
    fun syncNow(): Job? {
        synchronized(lock) { debounceJob?.cancel() }
        return requestSync(userInitiated = true)
    }

    /**
     * Called for every value of the active store's change signal. The engine's own
     * announcement (after it wrote downloaded files) is ignored so a sync never triggers itself;
     * anything else is debounced into one sync when sync-on-change is enabled.
     */
    fun storeChanged(store: NoteStore, version: Int) {
        if (isOwnChange(store, version)) return
        if (!syncOnChangeEnabled()) return
        synchronized(lock) {
            debounceJob?.cancel()
            debounceJob = scope.launch {
                delay(changeDebounceMillis)
                requestSync(userInitiated = false)
            }
        }
    }

    /** Whether [version] of [store]'s change signal is the engine's own announcement. */
    fun isOwnChange(store: NoteStore, version: Int): Boolean {
        val own = ownChange ?: return false
        return own.first === store && own.second == version
    }

    /**
     * Starts a triggered run, or marks a follow-up run if one is already going. Automatic
     * triggers are inert when sync is not configured. Returns the job running the sync (and any
     * follow-ups), or null when nothing started.
     */
    fun requestSync(userInitiated: Boolean): Job? {
        synchronized(lock) {
            if (isSyncing) {
                rerunRequested = true
                return null
            }
            isSyncing = true
        }
        val first = buildContext(userInitiated)
        if (first == null) {
            synchronized(lock) { isSyncing = false }
            return null
        }
        _status.value = SyncStatus.Syncing
        return scope.launch {
            var context: SyncContext = first
            while (true) {
                try {
                    this@SyncEngine.run(context)
                    _lastSyncAt.value = Instant.now()
                    _status.value = SyncStatus.Idle
                } catch (e: CancellationException) {
                    synchronized(lock) { isSyncing = false }
                    throw e
                } catch (e: Exception) {
                    log.severe("Sync failed: ${e.message}")
                    _status.value = SyncStatus.Error(SyncErrorMessage.describe(e))
                }
                val again = synchronized(lock) {
                    if (rerunRequested) {
                        rerunRequested = false
                        true
                    } else {
                        isSyncing = false
                        false
                    }
                }
                if (!again) break
                val next = buildContext(userInitiated = false)
                if (next == null) {
                    synchronized(lock) { isSyncing = false }
                    break
                }
                context = next
                _status.value = SyncStatus.Syncing
            }
        }
    }

    /** Asks [contextProvider] for a context, recording a status error when it fails. */
    private fun buildContext(userInitiated: Boolean): SyncContext? = try {
        contextProvider() ?: run {
            if (userInitiated) _status.value = SyncStatus.Error(SyncEngineError.NotConfigured.message!!)
            null
        }
    } catch (e: Exception) {
        log.severe("Sync context unavailable: ${e.message}")
        _status.value = SyncStatus.Error(SyncErrorMessage.describe(e))
        null
    }

    // MARK: Conflicts API

    /**
     * Reloads [conflicts] from [root]'s state for [identity], or clears it when either is null.
     * An unreadable state file is logged and reads as no conflicts, as on the desktop.
     */
    fun refreshConflicts(root: File?, identity: String?) {
        if (root == null || identity == null) {
            _conflicts.value = emptyList()
            return
        }
        _conflicts.value = try {
            openConflicts(root, identity)
        } catch (e: Exception) {
            log.severe("Could not read sync state: ${e.message}")
            emptyList()
        }
    }

    /** Settles a conflict using the production context. */
    suspend fun resolveConflict(key: String, choice: ConflictResolution) {
        val context = contextProvider() ?: throw SyncEngineError.NotConfigured
        resolveConflict(key, choice, context)
    }

    /** Settles a conflict against an explicit context. Serialized with sync runs. */
    suspend fun resolveConflict(key: String, choice: ConflictResolution, context: SyncContext) {
        mutex.withLock { withContext(Dispatchers.IO) { performResolve(key, choice, context) } }
    }

    // MARK: Running

    /** Runs one full sync against [context], serialized with any other run or resolution. */
    suspend fun run(context: SyncContext): SyncReport =
        mutex.withLock { withContext(Dispatchers.IO) { performSync(context) } }

    /** Mutable copy of a state during one run or resolution. */
    private class Working(val original: SyncState) {
        val entries = original.entries.toMutableMap()
        val conflicts = original.conflicts.toMutableList()

        /** The state as it now stands. */
        fun toState() = SyncState(original.configIdentity, entries.toMap(), conflicts.toList())
    }

    /** Scan, list, plan, apply, then persist state and announce what changed. */
    private suspend fun performSync(context: SyncContext): SyncReport {
        val root = context.root
        val work = Working(SyncState.load(root, context.identity))
        val report = SyncReport()

        val localHashes = scanLocal(root).mapValues { sha256Hex(it.value.readBytes()) }
        val remoteETags = context.store.list("")
            .filter { isSyncedKey(it.key) }
            .associate { it.key to it.etag }

        val actions = SyncPlanner.plan(
            localHashes, remoteETags, work.original.entries,
            work.original.conflicts.map { it.key }.toSet(),
        )
        try {
            for (action in actions) apply(action, context, work, report)
        } catch (e: Exception) {
            // Keep whatever progress was made so finished actions are not redone as conflicts.
            try {
                finish(work, report, root)
            } catch (saveError: Exception) {
                log.severe("Could not save sync state after failure: ${saveError.message}")
            }
            throw e
        }
        finish(work, report, root)
        return report
    }

    /** Carries out one planned action and records the new base for its key. */
    private suspend fun apply(action: SyncAction, context: SyncContext, work: Working, report: SyncReport) {
        val root = context.root
        val key = action.key
        when (action) {
            is SyncAction.Noop -> Unit
            is SyncAction.Forget -> work.entries.remove(key)
            is SyncAction.Upload -> {
                val data = localFile(key, root).readBytes()
                val etag = context.store.put(key, data)
                work.entries[key] = SyncState.Entry(sha256Hex(data), etag)
                report.uploaded.add(key)
            }
            is SyncAction.Download -> {
                val content = context.store.get(key)
                writeLocal(content.data, key, root)
                work.entries[key] = SyncState.Entry(sha256Hex(content.data), content.etag)
                report.downloaded.add(key)
            }
            is SyncAction.DeleteLocal -> {
                removeLocal(key, root)
                work.entries.remove(key)
                report.deletedLocal.add(key)
            }
            is SyncAction.DeleteRemote -> {
                context.store.delete(key)
                work.entries.remove(key)
                report.deletedRemote.add(key)
            }
            is SyncAction.Conflict -> recordConflictIfReal(key, context, work, report)
        }
    }

    /**
     * Fetches both sides of a planned conflict. Identical bytes (or both gone) settle it
     * silently; otherwise the remote copy is parked under `conflicts/` and the key is recorded.
     */
    private suspend fun recordConflictIfReal(key: String, context: SyncContext, work: Working, report: SyncReport) {
        val root = context.root
        val local = readLocalIfExists(key, root)
        val remote = getIfExists(key, context.store)

        if (local != null && remote != null && local.contentEquals(remote.data)) {
            work.entries[key] = SyncState.Entry(sha256Hex(local), remote.etag)
            return
        }
        if (local == null && remote == null) {
            work.entries.remove(key)
            return
        }

        val parked = SyncState.conflictFile(key, root)
        if (remote != null) {
            writeAtomically(remote.data, parked)
        } else if (parked.exists() && !parked.delete()) {
            throw IOException("cannot remove stale parked copy ${parked.path}")
        }
        work.conflicts.add(SyncState.Conflict(key, SyncState.now()))
        report.newConflicts.add(key)
    }

    /** Applies the user's choice for one conflicted key, then clears the conflict. */
    private suspend fun performResolve(key: String, choice: ConflictResolution, context: SyncContext) {
        val root = context.root
        val work = Working(SyncState.load(root, context.identity))
        if (!work.original.hasConflict(key)) throw SyncEngineError.NoSuchConflict(key)
        val report = SyncReport()

        val local = readLocalIfExists(key, root)
        val remote = getIfExists(key, context.store)

        when {
            choice == ConflictResolution.KEEP_LOCAL ||
                (choice == ConflictResolution.KEEP_BOTH && remote == null) ->
                pushLocal(key, local, context, work, report)
            choice == ConflictResolution.KEEP_REMOTE ||
                (choice == ConflictResolution.KEEP_BOTH && local == null) ->
                pullRemote(key, remote, root, work, report)
            else -> {
                // Keep both, and both sides exist.
                if (!local!!.contentEquals(remote!!.data)) {
                    val copyKey = remoteCopyKey(key, root, work.entries.keys)
                    writeLocal(remote.data, copyKey, root)
                    // The copy is the same note, so it keeps the original's document type
                    // (otherwise a checklist's remote copy would reopen as markdown).
                    val metadata = activeStore(root)?.metadata ?: NoteMetadataStore(root)
                    metadata.docType(localFile(key, root))?.let { metadata.setDocType(it, localFile(copyKey, root)) }
                    report.downloaded.add(copyKey)
                    if (isSyncedKey(copyKey)) {
                        val etag = context.store.put(copyKey, remote.data)
                        work.entries[copyKey] = SyncState.Entry(sha256Hex(remote.data), etag)
                        report.uploaded.add(copyKey)
                    }
                }
                pushLocal(key, local, context, work, report)
            }
        }

        work.conflicts.removeAll { it.key == key }
        val parked = SyncState.conflictFile(key, root)
        if (parked.exists() && !parked.delete()) throw IOException("cannot remove parked copy ${parked.path}")
        finish(work, report, root)
    }

    /** Uploads [data] under [key], or deletes the remote object when local is gone. */
    private suspend fun pushLocal(key: String, data: ByteArray?, context: SyncContext, work: Working, report: SyncReport) {
        if (data != null) {
            val etag = context.store.put(key, data)
            work.entries[key] = SyncState.Entry(sha256Hex(data), etag)
            report.uploaded.add(key)
        } else {
            context.store.delete(key)
            work.entries.remove(key)
            report.deletedRemote.add(key)
        }
    }

    /** Writes the remote body locally, or deletes the local file when remote is gone. */
    private fun pullRemote(key: String, remote: ObjectContent?, root: File, work: Working, report: SyncReport) {
        if (remote != null) {
            writeLocal(remote.data, key, root)
            work.entries[key] = SyncState.Entry(sha256Hex(remote.data), remote.etag)
            report.downloaded.add(key)
        } else {
            removeLocal(key, root)
            work.entries.remove(key)
            report.deletedLocal.add(key)
        }
    }

    /**
     * Saves the state if it changed, publishes the open conflicts, and bumps the active store's
     * change signal (once) when files under the root changed. The bump's version is remembered
     * so [storeChanged] can ignore it. The metadata sidecar needs no cache invalidation:
     * `NoteMetadataStore` re-reads the file on every access. `settings.plist` is opaque here.
     */
    private fun finish(work: Working, report: SyncReport, root: File) {
        val state = work.toState()
        // Skipping unchanged writes keeps an idle sync from touching the disk.
        if (state != work.original || !SyncState.fileOf(root).exists()) state.save(root)
        _conflicts.value = state.conflicts
        if (report.changedLocalFiles) {
            activeStore(root)?.let { store -> ownChange = store to store.postChange() }
        }
    }

    /** The active note store when it is rooted at [root], else null. */
    private fun activeStore(root: File): NoteStore? {
        val store = noteStoreProvider() ?: return null
        return if (canonical(store.root) == canonical(root)) store else null
    }

    companion object {
        /** Milliseconds of quiet after a local change before a sync starts. */
        const val CHANGE_DEBOUNCE_MS = 3_000L

        /** Store-relative keys of the two sidecar files that sync alongside notes. */
        const val METADATA_KEY = "${NoteMetadataStore.FOLDER_NAME}/${NoteMetadataStore.FILE_NAME}"
        const val SETTINGS_KEY = "${NoteMetadataStore.FOLDER_NAME}/settings.plist"

        private const val TEMP_SUFFIX = ".tq-tmp"

        /** Open conflicts recorded in [root]'s state for [identity]. */
        fun openConflicts(root: File, identity: String): List<SyncState.Conflict> =
            SyncState.load(root, identity).conflicts

        // MARK: Local file helpers

        /**
         * Whether a store-relative key belongs to the synced set: a non-hidden `.md` note at any
         * depth, or one of the two sidecar files. Rejects empty, `.`/`..` and hidden components,
         * so a remote key can never point outside the root or into `.thoughtqueue/`.
         */
        fun isSyncedKey(key: String): Boolean {
            if (key == METADATA_KEY || key == SETTINGS_KEY) return true
            val components = key.split("/")
            if (components.any { it.isEmpty() || it.startsWith(".") }) return false
            return components.last().substringAfterLast('.', "").lowercase() == "md"
        }

        /** The local file for a synced key. Throws for keys outside the synced set. */
        fun localFile(key: String, root: File): File {
            if (!isSyncedKey(key)) throw SyncEngineError.InvalidKey(key)
            return File(root, key)
        }

        /**
         * Every synced file under [root], keyed by '/'-separated root-relative path. Uses the
         * same rules as `NoteStore` (hidden entries skipped, `.md` files at any depth) plus the
         * sidecars.
         */
        fun scanLocal(root: File): Map<String, File> {
            val result = HashMap<String, File>()
            collect(root, "", result)
            for (key in listOf(METADATA_KEY, SETTINGS_KEY)) {
                val file = File(root, key)
                if (file.isFile) result[key] = file
            }
            return result
        }

        /** Recursive walk behind [scanLocal]. Throws when a folder cannot be listed. */
        private fun collect(dir: File, keyPrefix: String, result: MutableMap<String, File>) {
            val entries = dir.listFiles() ?: throw IOException("cannot list ${dir.path}")
            for (entry in entries) {
                if (entry.name.startsWith(".")) continue
                val key = keyPrefix + entry.name
                if (entry.isDirectory) collect(entry, "$key/", result)
                else if (entry.isFile && isSyncedKey(key)) result[key] = entry
            }
        }

        /** The local bytes for a key, or null when the file does not exist. */
        fun readLocalIfExists(key: String, root: File): ByteArray? {
            val file = localFile(key, root)
            return if (file.exists()) file.readBytes() else null
        }

        /** Writes a downloaded body atomically, creating intermediate folders (new categories). */
        fun writeLocal(data: ByteArray, key: String, root: File) {
            writeAtomically(data, localFile(key, root))
        }

        /** Writes [data] to [file] through a hidden temp file in the same folder, then renames it. */
        private fun writeAtomically(data: ByteArray, file: File) {
            val dir = file.parentFile!!
            if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create ${dir.path}")
            val tmp = File(dir, ".${file.name}$TEMP_SUFFIX")
            tmp.writeBytes(data)
            Files.move(tmp.toPath(), file.toPath(), StandardCopyOption.REPLACE_EXISTING, StandardCopyOption.ATOMIC_MOVE)
        }

        /** Deletes a local file if it exists. */
        fun removeLocal(key: String, root: File) {
            val file = localFile(key, root)
            if (file.exists() && !file.delete()) throw IOException("cannot delete ${file.path}")
        }

        /**
         * A free key beside [key] for the remote copy: "Name (remote).md", then
         * "Name (remote 2).md", and so on. A key is free when no local file exists and the base
         * state does not know it.
         */
        fun remoteCopyKey(key: String, root: File, taken: Set<String>): String {
            val slash = key.lastIndexOf('/')
            val dir = if (slash < 0) "" else key.substring(0, slash)
            val name = key.substring(slash + 1)
            val dot = name.lastIndexOf('.')
            val ext = if (dot > 0) name.substring(dot + 1) else ""
            val stem = if (dot > 0) name.substring(0, dot) else name
            for (counter in 1..999) {
                val suffix = if (counter == 1) " (remote)" else " (remote $counter)"
                val candidateName = stem + suffix + (if (ext.isEmpty()) "" else ".$ext")
                val candidate = if (dir.isEmpty()) candidateName else "$dir/$candidateName"
                if (candidate !in taken && !File(root, candidate).exists()) return candidate
            }
            throw SyncEngineError.InvalidKey(key)
        }

        /** Downloads an object, mapping a 404 to null. */
        suspend fun getIfExists(key: String, store: ObjectStore): ObjectContent? = try {
            store.get(key)
        } catch (e: S3ClientError.Service) {
            if (e.status == 404) null else throw e
        } catch (e: S3ClientError.Http) {
            if (e.status == 404) null else throw e
        }

        /** Lowercase hex SHA256 of [data]. */
        fun sha256Hex(data: ByteArray): String = SigV4.sha256Hex(data)

        /** A canonical path for comparing roots (Android's `/data/user/0` is a symlink). */
        private fun canonical(file: File): String = try {
            file.canonicalPath
        } catch (e: IOException) {
            file.absoluteFile.normalize().path
        }

        // MARK: Seeding the S3 cache

        /**
         * Copies the synced files of [source] (the local notes folder) into the S3 cache, so
         * switching to S3 mode carries existing notes along. Merge only: files already in the
         * cache, or keys the cache's base state knows about, are left alone. The next sync sees
         * the copied files as unsynced, so it uploads them, or records a conflict when the
         * bucket already has different content under the same key. Returns the copied keys.
         */
        fun seedCache(source: File, cache: File): List<String> {
            if (!cache.isDirectory && !cache.mkdirs()) throw IOException("cannot create ${cache.path}")
            val known = SyncState.loadAnyIdentity(cache)?.entries ?: emptyMap()
            val copied = ArrayList<String>()
            for ((key, file) in scanLocal(source).toSortedMap()) {
                if (key in known) continue
                val destination = localFile(key, cache)
                if (destination.exists()) continue
                val dir = destination.parentFile!!
                if (!dir.isDirectory && !dir.mkdirs()) throw IOException("cannot create ${dir.path}")
                Files.copy(file.toPath(), destination.toPath())
                copied.add(key)
            }
            return copied
        }
    }
}
