package com.thoughtqueue.app.prefs

import android.content.Context
import android.content.SharedPreferences
import com.thoughtqueue.app.sync.S3Config
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.io.File

/** Light/dark/system appearance choice. */
enum class ThemeMode { SYSTEM, LIGHT, DARK }

/** How a markdown note opens: rendered (read) or raw (edit). */
enum class EditMode { RENDERED, RAW }

/**
 * Where notes live, with the desktop's raw values. [LOCAL] is the app's notes folder with no
 * network, [S3] keeps a cache folder that mirrors the bucket, [BOTH] syncs the notes folder.
 */
enum class StorageMode(val raw: String) {
    LOCAL("local"),
    S3("s3"),
    BOTH("both");

    /** Whether this mode syncs with a bucket. */
    val syncs: Boolean get() = this != LOCAL

    /** The store root this mode uses: `filesDir/s3cache` for [S3], otherwise `filesDir/notes`. */
    fun storeRoot(filesDir: File): File = File(filesDir, if (this == S3) S3_CACHE_DIR else NOTES_DIR)

    companion object {
        const val NOTES_DIR = "notes"
        const val S3_CACHE_DIR = "s3cache"

        /** The mode for a raw value, or [LOCAL] for a missing or unknown one. */
        fun fromRaw(raw: String?): StorageMode = entries.firstOrNull { it.raw == raw } ?: LOCAL
    }
}

/**
 * S3 connection fields and sync triggers, as stored. The secret key is not here; it lives in
 * the encrypted `SecretStore`. Defaults match the desktop: path-style on, every trigger on.
 * [intervalMinutes] is clamped to WorkManager's 15 minute floor.
 */
data class SyncSettings(
    val endpoint: String = "",
    val region: String = "",
    val bucket: String = "",
    val prefix: String = "",
    val pathStyle: Boolean = true,
    val accessKeyId: String = "",
    val syncAtLaunch: Boolean = true,
    val syncOnChange: Boolean = true,
    val syncOnInterval: Boolean = true,
    val intervalMinutes: Int = MIN_INTERVAL_MINUTES,
) {
    /** The fields as an [S3Config], or null when the endpoint, bucket or access key is unusable. */
    fun s3Config(): S3Config? = S3Config.make(endpoint, region, bucket, prefix, pathStyle, accessKeyId)

    companion object {
        const val MIN_INTERVAL_MINUTES = 15
    }
}

/**
 * SharedPreferences-backed app settings. Values the UI needs to react to are mirrored in
 * [StateFlow]s so Compose can collect them.
 */
class Preferences(context: Context) {
    private val sp: SharedPreferences =
        context.getSharedPreferences("thoughtqueue", Context.MODE_PRIVATE)

    private val _themeMode = MutableStateFlow(readEnum(KEY_THEME_MODE, ThemeMode.SYSTEM))
    private val _lightThemeId = MutableStateFlow(sp.getString(KEY_LIGHT_THEME, null))
    private val _darkThemeId = MutableStateFlow(sp.getString(KEY_DARK_THEME, null))
    private val _editMode = MutableStateFlow(readEnum(KEY_EDIT_MODE, EditMode.RENDERED))
    private val _storageMode = MutableStateFlow(StorageMode.fromRaw(sp.getString(KEY_STORAGE_MODE, null)))
    private val _syncSettings = MutableStateFlow(readSyncSettings())

    /** Appearance choice; defaults to following the system. */
    val themeMode: StateFlow<ThemeMode> = _themeMode.asStateFlow()

    /** Selected light theme id, or null for the Organic Light default. */
    val lightThemeId: StateFlow<String?> = _lightThemeId.asStateFlow()

    /** Selected dark theme id, or null for the Organic Dark default. */
    val darkThemeId: StateFlow<String?> = _darkThemeId.asStateFlow()

    /** Whether a markdown note opens rendered or raw. */
    val editMode: StateFlow<EditMode> = _editMode.asStateFlow()

    /** Where notes live and whether they sync. Defaults to local. */
    val storageMode: StateFlow<StorageMode> = _storageMode.asStateFlow()

    /** S3 connection fields and sync triggers. */
    val syncSettings: StateFlow<SyncSettings> = _syncSettings.asStateFlow()

    /** Persist the storage mode. The app must then call `TqApp.syncConfigDidChange()`. */
    fun setStorageMode(mode: StorageMode) {
        sp.edit().putString(KEY_STORAGE_MODE, mode.raw).apply()
        _storageMode.value = mode
    }

    /**
     * Persist the sync settings, clamping the interval to the minimum. The app must then call
     * `TqApp.syncConfigDidChange()` so the schedule and conflicts follow.
     */
    fun setSyncSettings(settings: SyncSettings) {
        val clamped = settings.copy(
            intervalMinutes = settings.intervalMinutes.coerceAtLeast(SyncSettings.MIN_INTERVAL_MINUTES),
        )
        sp.edit()
            .putString(KEY_S3_ENDPOINT, clamped.endpoint)
            .putString(KEY_S3_REGION, clamped.region)
            .putString(KEY_S3_BUCKET, clamped.bucket)
            .putString(KEY_S3_PREFIX, clamped.prefix)
            .putBoolean(KEY_S3_PATH_STYLE, clamped.pathStyle)
            .putString(KEY_S3_ACCESS_KEY_ID, clamped.accessKeyId)
            .putBoolean(KEY_SYNC_AT_LAUNCH, clamped.syncAtLaunch)
            .putBoolean(KEY_SYNC_ON_CHANGE, clamped.syncOnChange)
            .putBoolean(KEY_SYNC_ON_INTERVAL, clamped.syncOnInterval)
            .putInt(KEY_SYNC_INTERVAL_MINUTES, clamped.intervalMinutes)
            .apply()
        _syncSettings.value = clamped
    }

    /** Reads the stored sync settings, using the defaults for anything missing. */
    private fun readSyncSettings(): SyncSettings {
        val d = SyncSettings()
        return SyncSettings(
            endpoint = sp.getString(KEY_S3_ENDPOINT, null) ?: d.endpoint,
            region = sp.getString(KEY_S3_REGION, null) ?: d.region,
            bucket = sp.getString(KEY_S3_BUCKET, null) ?: d.bucket,
            prefix = sp.getString(KEY_S3_PREFIX, null) ?: d.prefix,
            pathStyle = sp.getBoolean(KEY_S3_PATH_STYLE, d.pathStyle),
            accessKeyId = sp.getString(KEY_S3_ACCESS_KEY_ID, null) ?: d.accessKeyId,
            syncAtLaunch = sp.getBoolean(KEY_SYNC_AT_LAUNCH, d.syncAtLaunch),
            syncOnChange = sp.getBoolean(KEY_SYNC_ON_CHANGE, d.syncOnChange),
            syncOnInterval = sp.getBoolean(KEY_SYNC_ON_INTERVAL, d.syncOnInterval),
            intervalMinutes = sp.getInt(KEY_SYNC_INTERVAL_MINUTES, d.intervalMinutes)
                .coerceAtLeast(SyncSettings.MIN_INTERVAL_MINUTES),
        )
    }

    /** Persist the appearance choice. */
    fun setThemeMode(mode: ThemeMode) {
        sp.edit().putString(KEY_THEME_MODE, mode.name).apply()
        _themeMode.value = mode
    }

    /** Persist the light theme id (null restores the default). */
    fun setLightThemeId(id: String?) {
        sp.edit().putString(KEY_LIGHT_THEME, id).apply()
        _lightThemeId.value = id
    }

    /** Persist the dark theme id (null restores the default). */
    fun setDarkThemeId(id: String?) {
        sp.edit().putString(KEY_DARK_THEME, id).apply()
        _darkThemeId.value = id
    }

    /** Persist the default edit mode for markdown notes. */
    fun setEditMode(mode: EditMode) {
        sp.edit().putString(KEY_EDIT_MODE, mode.name).apply()
        _editMode.value = mode
    }

    /** Reads an enum preference, falling back to [default] for a missing or unknown value. */
    private inline fun <reified T : Enum<T>> readEnum(key: String, default: T): T =
        sp.getString(key, null)?.let { name -> enumValues<T>().firstOrNull { it.name == name } } ?: default

    private companion object {
        const val KEY_THEME_MODE = "themeMode"
        const val KEY_LIGHT_THEME = "lightThemeId"
        const val KEY_DARK_THEME = "darkThemeId"
        const val KEY_EDIT_MODE = "noteEditMode"
        const val KEY_STORAGE_MODE = "storageMode"
        const val KEY_S3_ENDPOINT = "s3Endpoint"
        const val KEY_S3_REGION = "s3Region"
        const val KEY_S3_BUCKET = "s3Bucket"
        const val KEY_S3_PREFIX = "s3Prefix"
        const val KEY_S3_PATH_STYLE = "s3UsePathStyle"
        const val KEY_S3_ACCESS_KEY_ID = "s3AccessKeyID"
        const val KEY_SYNC_AT_LAUNCH = "syncAtLaunch"
        const val KEY_SYNC_ON_CHANGE = "syncOnChange"
        const val KEY_SYNC_ON_INTERVAL = "syncOnInterval"
        const val KEY_SYNC_INTERVAL_MINUTES = "syncIntervalMinutes"
    }
}
