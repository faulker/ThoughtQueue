package com.thoughtqueue.app.sync

import android.content.Context
import android.content.SharedPreferences
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKeys
import java.io.IOException

/** Holds the S3 secret access key (the desktop keeps it in the Keychain). */
interface SecretStore {
    /** The stored secret, or null when none is saved. Throws when the store cannot be opened. */
    fun load(): String?

    /** Saves [secret]; null or empty deletes it. Throws when the write fails. */
    fun save(secret: String?)
}

/**
 * [SecretStore] backed by EncryptedSharedPreferences, whose key lives in the Android Keystore.
 * The secret never touches plain preferences. The file is excluded from backups (see
 * `res/xml/backup_rules.xml`) because a restored copy could not be decrypted on a new device.
 */
class EncryptedSecretStore(private val context: Context) : SecretStore {
    private val prefs: SharedPreferences by lazy {
        EncryptedSharedPreferences.create(
            FILE_NAME,
            MasterKeys.getOrCreate(MasterKeys.AES256_GCM_SPEC),
            context,
            EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
            EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM,
        )
    }

    /** Reads the secret, or null when none is stored. */
    override fun load(): String? = prefs.getString(KEY, null)

    /** Writes or removes the secret synchronously, throwing when the commit fails. */
    override fun save(secret: String?) {
        val editor = prefs.edit()
        if (secret.isNullOrEmpty()) editor.remove(KEY) else editor.putString(KEY, secret)
        if (!editor.commit()) throw IOException("Could not save the S3 secret key.")
    }

    companion object {
        /** Preferences file name; also referenced by the backup exclusion rules. */
        const val FILE_NAME = "thoughtqueue_secrets"
        private const val KEY = "s3-secret-key"
    }
}
