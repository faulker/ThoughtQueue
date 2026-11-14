package com.thoughtqueue.app.sync

import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.prefs.SyncSettings

/** Inline errors for the S3 form fields; null means the field is fine. */
data class SyncFormErrors(
    val endpoint: String? = null,
    val bucket: String? = null,
    val accessKeyId: String? = null,
    val interval: String? = null,
) {
    /** True when no field has an error. */
    val isValid: Boolean get() = endpoint == null && bucket == null && accessKeyId == null && interval == null
}

/**
 * The editable state of the Storage & Sync form, kept free of Android types so validation is
 * unit-testable. [secretInput] is what the user typed this session (blank means "leave as is");
 * [secretSaved] is whether the secret store already holds one.
 */
data class SyncForm(
    val endpoint: String = "",
    val region: String = "",
    val bucket: String = "",
    val prefix: String = "",
    val pathStyle: Boolean = true,
    val accessKeyId: String = "",
    val syncAtLaunch: Boolean = true,
    val syncOnChange: Boolean = true,
    val syncOnInterval: Boolean = true,
    val intervalText: String = SyncSettings.MIN_INTERVAL_MINUTES.toString(),
    val secretInput: String = "",
    val secretSaved: Boolean = false,
) {
    /** Per-field errors. Untouched empty fields are errors too, so Save and Test stay disabled. */
    fun errors(): SyncFormErrors {
        val minutes = intervalText.trim().toIntOrNull()
        val endpointOk = S3Config.make(endpoint, region, "b", prefix, pathStyle, "k") != null
        return SyncFormErrors(
            endpoint = when {
                endpoint.isBlank() -> "Required"
                !endpointOk -> "Enter a full http:// or https:// URL"
                else -> null
            },
            bucket = if (bucket.isBlank()) "Required" else null,
            accessKeyId = if (accessKeyId.isBlank()) "Required" else null,
            interval = if (minutes == null) "Enter a whole number" else null,
        )
    }

    /** True when the connection fields (not the interval) are valid. */
    val connectionValid: Boolean
        get() = errors().let { it.endpoint == null && it.bucket == null && it.accessKeyId == null }

    /** The connection as an [S3Config], or null when invalid. */
    fun s3Config(): S3Config? =
        if (connectionValid) S3Config.make(endpoint, region, bucket, prefix, pathStyle, accessKeyId) else null

    /** Whether a secret is available for testing or saving: typed now or already stored. */
    val hasSecret: Boolean get() = secretInput.isNotBlank() || secretSaved

    /** True when Save can run: valid fields and a usable interval. */
    val canSave: Boolean get() = errors().isValid

    /** The form as [SyncSettings]; the interval is clamped to the 15 minute floor. */
    fun toSettings(): SyncSettings = SyncSettings(
        endpoint = endpoint.trim(),
        region = region.trim(),
        bucket = bucket.trim(),
        prefix = prefix.trim(),
        pathStyle = pathStyle,
        accessKeyId = accessKeyId.trim(),
        syncAtLaunch = syncAtLaunch,
        syncOnChange = syncOnChange,
        syncOnInterval = syncOnInterval,
        intervalMinutes = (intervalText.trim().toIntOrNull() ?: SyncSettings.MIN_INTERVAL_MINUTES)
            .coerceAtLeast(SyncSettings.MIN_INTERVAL_MINUTES),
    )

    /** True when the typed interval is below the floor and will be raised on save. */
    val intervalWillClamp: Boolean
        get() = (intervalText.trim().toIntOrNull() ?: SyncSettings.MIN_INTERVAL_MINUTES) < SyncSettings.MIN_INTERVAL_MINUTES

    companion object {
        /** Builds the form from stored settings. */
        fun from(settings: SyncSettings, secretSaved: Boolean) = SyncForm(
            endpoint = settings.endpoint,
            region = settings.region,
            bucket = settings.bucket,
            prefix = settings.prefix,
            pathStyle = settings.pathStyle,
            accessKeyId = settings.accessKeyId,
            syncAtLaunch = settings.syncAtLaunch,
            syncOnChange = settings.syncOnChange,
            syncOnInterval = settings.syncOnInterval,
            intervalText = settings.intervalMinutes.toString(),
            secretSaved = secretSaved,
        )

        /**
         * Why [mode] cannot be chosen, or null when it can. Local always works; S3 and Both need
         * a valid saved config and a saved secret, judged from what is stored, not the form.
         */
        fun modeBlockReason(mode: StorageMode, saved: SyncSettings, secretSaved: Boolean): String? {
            if (!mode.syncs) return null
            if (saved.s3Config() == null) return "Save a valid endpoint, bucket and access key ID first."
            if (!secretSaved) return "Save the secret key first."
            return null
        }
    }
}
