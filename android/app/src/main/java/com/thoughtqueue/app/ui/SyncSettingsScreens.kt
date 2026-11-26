package com.thoughtqueue.app.ui

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.MutableState
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.prefs.StorageMode
import com.thoughtqueue.app.sync.SyncForm
import com.thoughtqueue.app.sync.SyncStatus
import com.thoughtqueue.app.sync.SyncSummary
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.Instant
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private val modeBlurbs = listOf(
    StorageMode.LOCAL to "Notes stay on this device. No network.",
    StorageMode.S3 to "Notes live in the bucket; this device keeps a cache.",
    StorageMode.BOTH to "Notes stay on this device and sync with the bucket.",
)

/** Formats a sync time for display, e.g. "Nov 26, 2026, 3:12 PM". */
fun formatLastSync(at: Instant): String =
    DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT).withZone(ZoneId.systemDefault()).format(at)

/**
 * Whether the secret store holds a secret, read off the main thread since the Keystore can be
 * slow. [onError] receives a message when the store cannot be read.
 */
@Composable
private fun rememberSecretSaved(app: TqApp, onError: (String) -> Unit): MutableState<Boolean> {
    val saved = remember { mutableStateOf(false) }
    LaunchedEffect(Unit) {
        try {
            saved.value = withContext(Dispatchers.IO) { !app.secrets.load().isNullOrEmpty() }
        } catch (e: Exception) {
            onError("Could not read the secret store: ${e.message}")
        }
    }
    return saved
}

/**
 * Storage & Sync page: sync status and Sync now first, then the storage mode, then a row into
 * the S3 connection page. Mode options are judged from saved values only
 * ([SyncForm.modeBlockReason]), so a half-typed form cannot enable syncing.
 */
@Composable
fun SyncSettingsScreen(app: TqApp, onBack: () -> Unit, onConflicts: () -> Unit, onS3: () -> Unit) {
    val palette = LocalPalette.current
    val savedSettings by app.prefs.syncSettings.collectAsState()
    val mode by app.prefs.storageMode.collectAsState()
    val status by app.sync.status.collectAsState()
    val lastSync by app.sync.lastSyncAt.collectAsState()
    val conflicts by app.sync.conflicts.collectAsState()
    var secretError by remember { mutableStateOf<String?>(null) }
    val secretSaved by rememberSecretSaved(app) { secretError = it }

    SettingsPage("Storage & Sync", onBack) {
        SectionTitle("Status")
        Text(
            lastSync?.let { "Last sync: " + formatLastSync(it) } ?: "Not synced yet this session.",
            style = MaterialTheme.typography.bodyMedium,
        )
        when (val s = status) {
            SyncStatus.Idle -> Unit
            SyncStatus.Syncing -> Text("Syncing...", style = MaterialTheme.typography.bodyMedium)
            is SyncStatus.Error -> Text(s.message, color = palette.danger, style = MaterialTheme.typography.bodyMedium)
        }
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(8.dp)) {
            OutlinedButton(enabled = mode.syncs && status != SyncStatus.Syncing, onClick = { app.syncNow() }) { Text("Sync now") }
            if (conflicts.isNotEmpty()) {
                TextButton(onClick = onConflicts) {
                    Text("${conflicts.size} conflict${if (conflicts.size == 1) "" else "s"}", color = palette.danger)
                }
            }
        }

        HorizontalDivider(color = palette.divider)
        SectionTitle("Storage")
        for ((m, blurb) in modeBlurbs) {
            val reason = SyncForm.modeBlockReason(m, savedSettings, secretSaved)
            val select = { app.prefs.setStorageMode(m); app.syncConfigDidChange() }
            Row(
                Modifier.fillMaxWidth().clickable(enabled = reason == null, onClick = select),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                RadioButton(selected = mode == m, enabled = reason == null, onClick = select)
                Column {
                    Text(SyncSummary.modeTitle(m), style = MaterialTheme.typography.bodyLarge)
                    Text(blurb, style = MaterialTheme.typography.bodySmall, color = palette.textSecondary)
                    reason?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.danger) }
                }
            }
        }

        HorizontalDivider(color = palette.divider)
        SettingsRow("S3 connection", SyncSummary.connection(savedSettings, secretSaved), onS3)
        secretError?.let { Text(it, color = palette.danger, style = MaterialTheme.typography.bodySmall) }
    }
}

/**
 * S3 connection page: connection fields, write-only secret, test connection, and sync triggers,
 * saved together by one Save. Validation lives in [SyncForm]. The secret is held only in this
 * composable's plain state (never saved instance state) and written to the SecretStore on Save.
 */
@Composable
fun S3SettingsScreen(app: TqApp, onBack: () -> Unit) {
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    val savedSettings by app.prefs.syncSettings.collectAsState()
    val mode by app.prefs.storageMode.collectAsState()

    var form by remember { mutableStateOf(SyncForm.from(savedSettings, secretSaved = false)) }
    var secretError by remember { mutableStateOf<String?>(null) }
    var secretSaved by rememberSecretSaved(app) { secretError = it }
    var testing by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<String?>(null) }
    var testOk by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    // The form tracks the stored secret so its validity matches what Save would produce.
    LaunchedEffect(secretSaved) { form = form.copy(secretSaved = secretSaved) }

    val errors = form.errors()
    val busy = testing

    SettingsPage("S3 connection", onBack) {
        SectionTitle("Bucket")
        FormField("Endpoint", form.endpoint, errors.endpoint, "https://s3.amazonaws.com", KeyboardType.Uri) {
            form = form.copy(endpoint = it); testResult = null
        }
        FormField("Region", form.region, null, "us-east-1 (default)") { form = form.copy(region = it); testResult = null }
        FormField("Bucket", form.bucket, errors.bucket) { form = form.copy(bucket = it); testResult = null }
        FormField("Prefix (optional)", form.prefix, null, "notes/") { form = form.copy(prefix = it); testResult = null }
        Row(verticalAlignment = Alignment.CenterVertically) {
            Column(Modifier.weight(1f)) {
                Text("Path-style addressing")
                Text(
                    "Leave on for MinIO and RustFS. Turn off for AWS virtual-host style.",
                    style = MaterialTheme.typography.bodySmall,
                    color = palette.textSecondary,
                )
            }
            Switch(form.pathStyle, { form = form.copy(pathStyle = it); testResult = null })
        }

        HorizontalDivider(color = palette.divider)
        SectionTitle("Credentials")
        FormField("Access key ID", form.accessKeyId, errors.accessKeyId) { form = form.copy(accessKeyId = it); testResult = null }
        // Secret key: write-only, so only its presence is shown.
        Text(
            if (secretSaved) "Secret key: Saved" else "Secret key: Not set",
            color = if (secretSaved) palette.textPrimary else palette.textSecondary,
        )
        OutlinedTextField(
            value = form.secretInput,
            onValueChange = { form = form.copy(secretInput = it); testResult = null },
            label = { Text(if (secretSaved) "Replace secret key" else "Secret key") },
            singleLine = true,
            visualTransformation = PasswordVisualTransformation(),
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Password, autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
            modifier = Modifier.fillMaxWidth(),
        )
        secretError?.let { Text(it, color = palette.danger, style = MaterialTheme.typography.bodySmall) }
        if (secretSaved) {
            TextButton(onClick = {
                scope.launch {
                    try {
                        withContext(Dispatchers.IO) { app.secrets.save(null) }
                        secretSaved = false
                        secretError = null
                        form = form.copy(secretSaved = false, secretInput = "")
                        // Syncing without a secret is impossible, so fall back to local.
                        if (mode.syncs) {
                            app.prefs.setStorageMode(StorageMode.LOCAL)
                            message = "Secret cleared. Switched to Local only."
                        } else {
                            message = "Secret cleared."
                        }
                        app.syncConfigDidChange()
                    } catch (e: Exception) {
                        secretError = "Could not clear the secret: ${e.message}"
                    }
                }
            }) { Text("Clear secret", color = palette.danger) }
        }

        // Test connection with the values in the fields, saved or not.
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(12.dp)) {
            OutlinedButton(
                enabled = form.connectionValid && form.hasSecret && !busy,
                onClick = {
                    val config = form.s3Config() ?: return@OutlinedButton
                    testing = true
                    testResult = null
                    scope.launch {
                        val secret = form.secretInput.ifBlank {
                            try {
                                withContext(Dispatchers.IO) { app.secrets.load().orEmpty() }
                            } catch (e: Exception) {
                                ""
                            }
                        }
                        val error = if (secret.isBlank()) "No secret key available." else app.testConnection(config, secret)
                        testOk = error == null
                        testResult = error ?: "Connection OK."
                        testing = false
                    }
                },
            ) { Text("Test connection") }
            if (testing) CircularProgressIndicator(Modifier.padding(4.dp), strokeWidth = 2.dp)
        }
        if (!form.hasSecret) Text("Enter a secret key to test.", style = MaterialTheme.typography.bodySmall, color = palette.textSecondary)
        testResult?.let { Text(it, color = if (testOk) palette.textPrimary else palette.danger, style = MaterialTheme.typography.bodyMedium) }

        HorizontalDivider(color = palette.divider)
        SectionTitle("Sync triggers")
        SwitchRow("Sync on launch", form.syncAtLaunch) { form = form.copy(syncAtLaunch = it) }
        SwitchRow("Sync after changes", form.syncOnChange) { form = form.copy(syncOnChange = it) }
        SwitchRow("Sync on an interval", form.syncOnInterval) { form = form.copy(syncOnInterval = it) }
        OutlinedTextField(
            value = form.intervalText,
            onValueChange = { form = form.copy(intervalText = it.filter(Char::isDigit)) },
            label = { Text("Interval (minutes)") },
            isError = errors.interval != null,
            supportingText = {
                Text(
                    errors.interval
                        ?: if (form.intervalWillClamp) "Android runs periodic sync at most every 15 minutes, so this will be saved as 15."
                        else "Minimum 15. Android enforces this for background work.",
                )
            },
            singleLine = true,
            keyboardOptions = KeyboardOptions(keyboardType = KeyboardType.Number, autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
            modifier = Modifier.fillMaxWidth(),
        )

        Button(
            enabled = form.canSave && !busy,
            onClick = {
                scope.launch {
                    try {
                        if (form.secretInput.isNotBlank()) {
                            withContext(Dispatchers.IO) { app.secrets.save(form.secretInput.trim()) }
                            secretSaved = true
                        }
                        app.prefs.setSyncSettings(form.toSettings())
                        form = form.toSettings().let { SyncForm.from(it, secretSaved) }
                        secretError = null
                        message = "Saved."
                        app.syncConfigDidChange()
                    } catch (e: Exception) {
                        secretError = "Could not save the secret: ${e.message}"
                    }
                }
            },
        ) { Text("Save") }
        message?.let { Text(it, style = MaterialTheme.typography.bodyMedium) }
    }
}

/** A single-line outlined text field with an optional inline error and placeholder. */
@Composable
private fun FormField(
    label: String,
    value: String,
    error: String?,
    placeholder: String? = null,
    keyboardType: KeyboardType = KeyboardType.Ascii,
    onChange: (String) -> Unit,
) {
    OutlinedTextField(
        value = value,
        onValueChange = onChange,
        label = { Text(label) },
        placeholder = placeholder?.let { { Text(it) } },
        isError = error != null && value.isNotEmpty(),
        supportingText = if (error != null && value.isNotEmpty()) ({ Text(error) }) else null,
        singleLine = true,
        keyboardOptions = KeyboardOptions(keyboardType = keyboardType, autoCorrectEnabled = false, capitalization = KeyboardCapitalization.None),
        modifier = Modifier.fillMaxWidth(),
    )
}

/** A label with a trailing switch. */
@Composable
private fun SwitchRow(label: String, checked: Boolean, onChange: (Boolean) -> Unit) {
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        Text(label, Modifier.weight(1f))
        Switch(checked, onChange)
    }
}
