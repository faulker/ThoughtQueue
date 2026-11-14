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
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.time.ZoneId
import java.time.format.DateTimeFormatter
import java.time.format.FormatStyle

private val modeInfo = listOf(
    Triple(StorageMode.LOCAL, "Local only", "Notes stay on this device. No network."),
    Triple(StorageMode.S3, "S3 only", "Notes live in the bucket; this device keeps a cache."),
    Triple(StorageMode.BOTH, "Local + S3", "Notes stay on this device and sync with the bucket."),
)

/**
 * The "Storage & Sync" settings block: storage mode, S3 connection fields, write-only secret,
 * test connection, sync triggers, and sync status. Validation lives in [SyncForm]. The secret
 * is held only in this composable's plain state (never saved instance state) and written to
 * the SecretStore on Save.
 */
@Composable
fun SyncSettingsSection(app: TqApp, onConflicts: () -> Unit) {
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    val savedSettings by app.prefs.syncSettings.collectAsState()
    val mode by app.prefs.storageMode.collectAsState()
    val status by app.sync.status.collectAsState()
    val lastSync by app.sync.lastSyncAt.collectAsState()
    val conflicts by app.sync.conflicts.collectAsState()

    var form by remember { mutableStateOf(SyncForm.from(savedSettings, secretSaved = false)) }
    var secretSaved by remember { mutableStateOf(false) }
    var secretError by remember { mutableStateOf<String?>(null) }
    var testing by remember { mutableStateOf(false) }
    var testResult by remember { mutableStateOf<String?>(null) }
    var testOk by remember { mutableStateOf(false) }
    var message by remember { mutableStateOf<String?>(null) }

    // Whether a secret is stored; read off the main thread since the Keystore can be slow.
    LaunchedEffect(Unit) {
        try {
            val has = withContext(Dispatchers.IO) { !app.secrets.load().isNullOrEmpty() }
            secretSaved = has
            form = form.copy(secretSaved = has)
        } catch (e: Exception) {
            secretError = "Could not read the secret store: ${e.message}"
        }
    }

    val errors = form.errors()
    val busy = testing

    Text("Storage & Sync", style = MaterialTheme.typography.titleMedium, color = palette.accentBorder)

    // Storage mode: judged from saved values, so a half-typed form cannot enable syncing.
    for ((m, title, blurb) in modeInfo) {
        val reason = SyncForm.modeBlockReason(m, savedSettings, secretSaved)
        Row(
            Modifier.fillMaxWidth().clickable(enabled = reason == null) {
                app.prefs.setStorageMode(m)
                app.syncConfigDidChange()
            },
            verticalAlignment = Alignment.CenterVertically,
        ) {
            RadioButton(
                selected = mode == m,
                enabled = reason == null,
                onClick = { app.prefs.setStorageMode(m); app.syncConfigDidChange() },
            )
            Column {
                Text(title, style = MaterialTheme.typography.bodyLarge)
                Text(blurb, style = MaterialTheme.typography.bodySmall, color = palette.textSecondary)
                reason?.let { Text(it, style = MaterialTheme.typography.bodySmall, color = palette.danger) }
            }
        }
    }

    HorizontalDivider(color = palette.divider)
    Text("S3 connection", style = MaterialTheme.typography.titleSmall)
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
    Text("Sync triggers", style = MaterialTheme.typography.titleSmall)
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

    HorizontalDivider(color = palette.divider)
    Text("Sync status", style = MaterialTheme.typography.titleSmall)
    Text(
        lastSync?.let { "Last sync: " + DateTimeFormatter.ofLocalizedDateTime(FormatStyle.MEDIUM, FormatStyle.SHORT)
            .withZone(ZoneId.systemDefault()).format(it) } ?: "Not synced yet this session.",
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
