package com.thoughtqueue.app

import android.app.Application
import com.thoughtqueue.app.prefs.Preferences
import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.store.NoteStore
import com.thoughtqueue.app.sync.EncryptedSecretStore
import com.thoughtqueue.app.sync.S3Client
import com.thoughtqueue.app.sync.S3Config
import com.thoughtqueue.app.sync.SecretStore
import com.thoughtqueue.app.sync.SyncContext
import com.thoughtqueue.app.sync.SyncEngine
import com.thoughtqueue.app.sync.SyncErrorMessage
import com.thoughtqueue.app.sync.SyncScheduler
import com.thoughtqueue.app.sync.SyncState
import com.thoughtqueue.app.ui.theme.ThemeLibrary
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.flow.drop
import kotlinx.coroutines.launch
import java.io.File
import java.io.IOException
import java.util.logging.Logger

/**
 * Application singleton holding the shared services. The note store's root follows the storage
 * mode (`filesDir/notes` or `filesDir/s3cache`), so [store] is re-created when the mode changes;
 * UI that must follow a switch collects [storeFlow].
 */
class TqApp : Application() {
    lateinit var prefs: Preferences
        private set
    lateinit var themes: ThemeLibrary
        private set
    lateinit var secrets: SecretStore
        private set
    lateinit var sync: SyncEngine
        private set

    private val log = Logger.getLogger("TqApp")
    private lateinit var storeState: MutableStateFlow<NoteStore>

    /** Long-lived scope for sync work and trigger collection. */
    val appScope = CoroutineScope(SupervisorJob() + Dispatchers.Default)

    /** The active note store; replaced when the storage mode moves the root. */
    val storeFlow: StateFlow<NoteStore> get() = storeState.asStateFlow()

    /** The active note store right now. */
    val store: NoteStore get() = storeState.value

    /** Create preferences, themes, the note store and the sync engine, then start the triggers. */
    override fun onCreate() {
        super.onCreate()
        prefs = Preferences(this)
        themes = ThemeLibrary(File(filesDir, "themes")).also { it.reload() }
        secrets = EncryptedSecretStore(this)
        storeState = MutableStateFlow(NoteStore(prefs.storageMode.value.storeRoot(filesDir), prefs))
        sync = SyncEngine(
            scope = appScope,
            contextProvider = ::syncContext,
            noteStoreProvider = { store },
            syncOnChangeEnabled = { prefs.storageMode.value.syncs && prefs.syncSettings.value.syncOnChange },
        )

        // Debounced change trigger. drop(1) skips each store's current value; the engine ignores
        // the version it announced itself after writing downloaded files.
        appScope.launch {
            storeFlow.collectLatest { s -> s.changes.drop(1).collect { v -> sync.storeChanged(s, v) } }
        }
        refreshSyncState()
        if (prefs.syncSettings.value.syncAtLaunch) sync.requestSync(userInitiated = false)
    }

    /**
     * Builds the context for a sync run: null in local mode, when the config or secret is
     * missing, or while the store root does not match the mode (mid-switch), so nothing syncs
     * the wrong folder. Throws when the secret store cannot be read.
     */
    private fun syncContext(): SyncContext? {
        val mode = prefs.storageMode.value
        if (!mode.syncs) return null
        val config = prefs.syncSettings.value.s3Config() ?: return null
        val current = store
        if (canonical(current.root) != canonical(mode.storeRoot(filesDir))) return null
        val secret = secrets.load()?.takeIf { it.isNotEmpty() } ?: return null
        return SyncContext(S3Client(config, secret), current.root, SyncState.identity(config))
    }

    /**
     * Applies changed storage mode or sync settings: moves the store root (seeding the S3 cache
     * from the notes folder when switching into S3 mode, merge only), reschedules the periodic
     * worker and reloads the open conflicts. Settings UI calls this after saving.
     */
    fun syncConfigDidChange() {
        val mode = prefs.storageMode.value
        val newRoot = mode.storeRoot(filesDir)
        val oldRoot = store.root
        if (canonical(oldRoot) != canonical(newRoot)) {
            if (mode == StorageMode.S3) {
                try {
                    val copied = SyncEngine.seedCache(oldRoot, newRoot)
                    log.info("Seeded S3 cache with ${copied.size} files")
                } catch (e: Exception) {
                    log.severe("Seeding the S3 cache failed: ${e.message}")
                }
            }
            storeState.value = NoteStore(newRoot, prefs)
        }
        refreshSyncState()
    }

    /** Reschedules the periodic worker and reloads conflicts for the current root and config. */
    private fun refreshSyncState() {
        val mode = prefs.storageMode.value
        val settings = prefs.syncSettings.value
        val config = settings.s3Config()
        SyncScheduler.apply(this, mode.syncs && config != null && settings.syncOnInterval, settings.intervalMinutes)
        sync.refreshConflicts(store.root, config?.let(SyncState::identity))
    }

    /** Runs a sync now; a missing configuration shows up as an error in `sync.status`. */
    fun syncNow() {
        sync.syncNow()
    }

    /**
     * Checks that [config] and [secret] can reach the bucket. Returns null on success, or a
     * user-readable error message.
     */
    suspend fun testConnection(config: S3Config, secret: String): String? = try {
        S3Client(config, secret).testConnection()
        null
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        SyncErrorMessage.describe(e)
    }

    /** A canonical path for comparing roots. */
    private fun canonical(file: File): String = try {
        file.canonicalPath
    } catch (e: IOException) {
        file.absoluteFile.normalize().path
    }
}
