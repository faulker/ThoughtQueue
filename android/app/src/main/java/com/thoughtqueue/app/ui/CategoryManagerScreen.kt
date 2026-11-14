package com.thoughtqueue.app.ui

import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Unarchive
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.delay

/** A category with its archive flag and note count, for the manager list. */
private data class CategoryInfo(val name: String, val archived: Boolean, val count: Int)

/**
 * Category manager: add, rename, archive or unarchive, and delete categories. Deleting moves the
 * category's notes to Uncategorized (after an inline confirmation); archiving only hides the
 * folder's notes from the notes list.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun CategoryManagerScreen(app: TqApp, onBack: () -> Unit) {
    val store = app.store
    val context = LocalContext.current
    val categories = storeQuery(store, emptyList()) {
        categories().map { CategoryInfo(it, isArchived(it), notes(it).size) }
    }
    var newName by remember { mutableStateOf("") }

    /** Toast a failure from a store operation. */
    fun report(ok: Boolean, what: String) {
        if (!ok) Toast.makeText(context, "Could not $what", Toast.LENGTH_SHORT).show()
    }

    Scaffold(topBar = { TopAppBar(title = { Text("Categories") }, navigationIcon = { BackButton(onBack) }) }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            Row(
                Modifier.fillMaxWidth().padding(16.dp),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                OutlinedTextField(
                    newName, { newName = it }, Modifier.weight(1f),
                    label = { Text("New category") }, singleLine = true,
                )
                Button(onClick = { report(store.createCategory(newName), "add category"); newName = "" }, enabled = newName.isNotBlank()) {
                    Text("Add")
                }
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(categories, key = { it.name }) { info -> CategoryRow(info, app, ::report) }
            }
        }
    }
}

/** One manager row with inline rename and inline delete confirmation. */
@Composable
private fun CategoryRow(info: CategoryInfo, app: TqApp, report: (Boolean, String) -> Unit) {
    val store = app.store
    val palette = LocalPalette.current
    var renaming by remember { mutableStateOf(false) }
    var confirming by remember { mutableStateOf(false) }
    var draft by remember(info.name) { mutableStateOf(info.name) }

    LaunchedEffect(confirming) {
        if (confirming) {
            delay(4000)
            confirming = false
        }
    }

    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 4.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (renaming) {
            OutlinedTextField(draft, { draft = it }, Modifier.weight(1f), singleLine = true)
            TextButton(onClick = {
                report(store.renameCategory(info.name, draft), "rename category")
                renaming = false
            }) { Text("Save") }
            TextButton(onClick = { renaming = false; draft = info.name }) { Text("Cancel") }
        } else {
            Column(Modifier.weight(1f)) {
                Text(info.name, style = MaterialTheme.typography.titleMedium)
                Text(
                    "${info.count} notes" + if (info.archived) ", archived" else "",
                    style = MaterialTheme.typography.labelMedium, color = palette.textSecondary,
                )
            }
            if (confirming) {
                Text("Delete?", color = palette.danger)
                TextButton(onClick = {
                    confirming = false
                    report(store.deleteCategory(info.name), "delete category")
                }) { Text("Yes", color = palette.danger) }
                TextButton(onClick = { confirming = false }) { Text("No") }
            } else {
                IconButton(onClick = { renaming = true }) { Icon(Icons.Default.Edit, "Rename") }
                IconButton(onClick = { report(store.setArchived(!info.archived, info.name), "archive category") }) {
                    Icon(if (info.archived) Icons.Default.Unarchive else Icons.Default.Archive, if (info.archived) "Unarchive" else "Archive")
                }
                IconButton(onClick = { confirming = true }) { Icon(Icons.Default.Delete, "Delete") }
            }
        }
    }
}
