package com.thoughtqueue.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.update.UpdateController
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.launch

/**
 * Settings block: the running version, the last check's outcome, and a button that either
 * checks now or downloads a release that is already known.
 */
@Composable
fun UpdateSettingsSection(app: TqApp) {
    val status by app.updates.status.collectAsState()
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var prompt by remember { mutableStateOf<String?>(null) }
    val busy = status is UpdateController.Status.Checking || status is UpdateController.Status.Downloading
    val offer = status.offerVersion()

    Text("Updates", style = MaterialTheme.typography.titleMedium, color = palette.accentBorder)
    Text("ThoughtQueue ${app.updates.runningVersion}", style = MaterialTheme.typography.bodyMedium)
    val line = status.describe()
    if (line.isNotEmpty()) {
        Text(
            line,
            color = if (status is UpdateController.Status.Failed) palette.danger else palette.textSecondary,
            style = MaterialTheme.typography.bodyMedium,
        )
    }
    OutlinedButton(
        onClick = {
            if (offer != null) {
                prompt = offer
            } else {
                scope.launch {
                    val release = app.updates.check()
                    if (release != null) prompt = release.version
                }
            }
        },
        enabled = !busy,
    ) { Text(if (offer != null) "Download and install" else "Check for updates") }

    if (prompt != null) {
        UpdateAvailableDialog(
            current = app.updates.runningVersion,
            available = prompt!!,
            onUpdate = {
                val version = prompt ?: return@UpdateAvailableDialog
                prompt = null
                app.updates.install(version)
            },
            onLater = { prompt = null },
        )
    }
}

/**
 * A strip on the notes list when a newer release is known, downloading, or waiting for the
 * system installer. Tapping a known release asks before downloading.
 */
@Composable
fun UpdateBanner(app: TqApp) {
    val status by app.updates.status.collectAsState()
    var prompt by remember { mutableStateOf<String?>(null) }
    val offer = status.offerVersion()
    val visible = status is UpdateController.Status.Available ||
        status is UpdateController.Status.Downloading ||
        status is UpdateController.Status.AwaitingConfirm ||
        (status is UpdateController.Status.Failed && offer != null)
    if (!visible) return

    val text = status.describe()
    val palette = LocalPalette.current
    var modifier = Modifier
        .fillMaxWidth()
        .padding(horizontal = 16.dp, vertical = 4.dp)
        .background(palette.accentSoftBackground, RoundedCornerShape(8.dp))
    if (offer != null && status !is UpdateController.Status.Downloading) {
        modifier = modifier.clickable { prompt = offer }
    }
    Text(
        text,
        color = palette.accent,
        style = MaterialTheme.typography.labelLarge,
        modifier = modifier.padding(12.dp),
    )

    if (prompt != null) {
        UpdateAvailableDialog(
            current = app.updates.runningVersion,
            available = prompt!!,
            onUpdate = {
                val version = prompt ?: return@UpdateAvailableDialog
                prompt = null
                app.updates.install(version)
            },
            onLater = { prompt = null },
        )
    }
}

/** Asks before downloading [available] over the running [current] version. */
@Composable
private fun UpdateAvailableDialog(
    current: String,
    available: String,
    onUpdate: () -> Unit,
    onLater: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onLater,
        title = { Text("ThoughtQueue $available is available") },
        text = { Text("You're running $current. ThoughtQueue will download the update and open the system installer.") },
        confirmButton = { TextButton(onClick = onUpdate) { Text("Update") } },
        dismissButton = { TextButton(onClick = onLater) { Text("Later") } },
    )
}
