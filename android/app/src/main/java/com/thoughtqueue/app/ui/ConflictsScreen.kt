package com.thoughtqueue.app.ui

import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
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
import com.thoughtqueue.app.sync.ConflictResolution
import com.thoughtqueue.app.sync.SyncErrorMessage
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.launch

/** A tappable strip on the notes list announcing open sync conflicts. */
@Composable
fun ConflictBanner(count: Int, onClick: () -> Unit) {
    val palette = LocalPalette.current
    Text(
        if (count == 1) "1 sync conflict needs attention" else "$count sync conflicts need attention",
        color = palette.danger,
        style = MaterialTheme.typography.labelLarge,
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 4.dp)
            .background(palette.accentSoftBackground, RoundedCornerShape(8.dp))
            .clickable(onClick = onClick)
            .padding(12.dp),
    )
}

/**
 * Lists the keys with open sync conflicts. Each offers Keep local (upload it over the remote),
 * Keep remote (replace the local copy) or Keep both (save the remote beside it as
 * "Name (remote).md"). The list updates itself from the engine as conflicts are resolved.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ConflictsScreen(app: TqApp, onBack: () -> Unit) {
    val conflicts by app.sync.conflicts.collectAsState()
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var busyKey by remember { mutableStateOf<String?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    /** Resolves one conflict, showing any failure under the title. */
    fun resolve(key: String, choice: ConflictResolution) {
        busyKey = key
        error = null
        scope.launch {
            try {
                app.sync.resolveConflict(key, choice)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                error = SyncErrorMessage.describe(e)
            } finally {
                busyKey = null
            }
        }
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Sync conflicts") }, navigationIcon = { BackButton(onBack) }) }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            error?.let { Text(it, color = palette.danger, modifier = Modifier.padding(16.dp)) }
            if (conflicts.isEmpty()) {
                Text("No conflicts.", color = palette.textSecondary, modifier = Modifier.padding(16.dp))
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(conflicts, key = { it.key }) { conflict ->
                    val enabled = busyKey == null
                    Column(Modifier.fillMaxWidth().padding(16.dp)) {
                        Text(conflict.key, style = MaterialTheme.typography.titleMedium)
                        Text(
                            "Changed on this device and in the bucket.",
                            color = palette.textSecondary,
                            style = MaterialTheme.typography.bodySmall,
                        )
                        Row(Modifier.fillMaxWidth().padding(top = 8.dp), horizontalArrangement = Arrangement.spacedBy(8.dp)) {
                            OutlinedButton(onClick = { resolve(conflict.key, ConflictResolution.KEEP_LOCAL) }, Modifier.weight(1f), enabled = enabled) {
                                Text("Keep local")
                            }
                            OutlinedButton(onClick = { resolve(conflict.key, ConflictResolution.KEEP_REMOTE) }, Modifier.weight(1f), enabled = enabled) {
                                Text("Keep remote")
                            }
                            OutlinedButton(onClick = { resolve(conflict.key, ConflictResolution.KEEP_BOTH) }, Modifier.weight(1f), enabled = enabled) {
                                Text("Keep both")
                            }
                        }
                    }
                    HorizontalDivider(color = palette.divider)
                }
            }
        }
    }
}
