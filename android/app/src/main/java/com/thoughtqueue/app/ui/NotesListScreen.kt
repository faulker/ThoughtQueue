package com.thoughtqueue.app.ui

import android.widget.Toast
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FileCopy
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.Button
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TopAppBar
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
import androidx.compose.ui.platform.LocalClipboardManager
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.AnnotatedString
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.store.FuzzySearch
import com.thoughtqueue.app.store.Note
import com.thoughtqueue.app.store.NoteDocType
import com.thoughtqueue.app.store.NoteMetadataStore
import com.thoughtqueue.app.store.TaskList
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

/**
 * The popover equivalent: a searchable list of notes (archived folders hidden) with copy, clone
 * and inline-confirmed delete per row, plus "+ Add" (markdown) and "+ List" (checklist).
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesListScreen(
    app: TqApp,
    onOpenNote: (String) -> Unit,
    onNavigator: () -> Unit,
    onCategories: () -> Unit,
    onSettings: () -> Unit,
    onConflicts: () -> Unit,
) {
    val store = app.store
    val context = LocalContext.current
    val conflicts by app.sync.conflicts.collectAsState()
    val notes = storeQuery(store, emptyList()) { visibleNotes() }
    val workingPath = storeQuery(store, null as String?) { workingDocumentPath }
    var query by remember { mutableStateOf("") }
    val shown = FuzzySearch.rank(notes, query)

    /** Create a note and open it, or toast when creation failed. */
    fun create(body: String, type: NoteDocType) {
        val note = store.createNote("", body, null, type)
        val key = note?.let { NoteMetadataStore.key(it.file, store.root) }
        if (key != null) onOpenNote(key) else Toast.makeText(context, "Could not create note", Toast.LENGTH_SHORT).show()
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("ThoughtQueue") },
                actions = {
                    IconButton(onClick = onNavigator) { Icon(Icons.Default.Menu, "Navigator") }
                    IconButton(onClick = onCategories) { Icon(Icons.Default.Folder, "Categories") }
                    IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, "Settings") }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (conflicts.isNotEmpty()) ConflictBanner(conflicts.size, onConflicts)
            SearchField(query, { query = it }, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            Row(
                Modifier.padding(horizontal = 16.dp, vertical = 4.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp),
            ) {
                Button(onClick = { create("", NoteDocType.MARKDOWN) }) { Text("+ Add") }
                OutlinedButton(onClick = { create(TaskList.NEW_ITEM_PREFIX, NoteDocType.CHECKLIST) }) { Text("+ List") }
            }
            if (shown.isEmpty()) {
                Text(
                    if (query.isBlank()) "No notes yet. Add one, or share text to ThoughtQueue." else "No matches",
                    Modifier.padding(16.dp),
                    color = LocalPalette.current.textSecondary,
                )
            }
            LazyColumn(Modifier.fillMaxSize()) {
                items(shown, key = { it.file.path }) { note ->
                    NoteRow(
                        app, note,
                        isWorking = workingPath != null && workingPath == NoteMetadataStore.key(note.file, store.root),
                        onOpen = { onOpenNote(NoteMetadataStore.key(note.file, store.root) ?: return@NoteRow) },
                    )
                }
            }
        }
    }
}

/**
 * One list row. Actions are copy body, clone and delete; delete swaps the action strip for an
 * inline "Delete?" prompt that cancels itself after a few seconds (no modal dialog).
 */
@Composable
private fun NoteRow(app: TqApp, note: Note, isWorking: Boolean, onOpen: () -> Unit) {
    val store = app.store
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }

    LaunchedEffect(confirming) {
        if (confirming) {
            delay(4000)
            confirming = false
        }
    }

    Row(
        Modifier.fillMaxWidth().clickable(onClick = onOpen).padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                if (isWorking) Icon(Icons.Default.Star, "Working document", tint = palette.accent)
                Text(note.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            }
            Spacer(Modifier.padding(top = 2.dp))
            CategoryPill(note.categoryDisplay, tintIndex(note.category))
        }
        if (confirming) {
            Text("Delete?", color = palette.danger, style = MaterialTheme.typography.labelLarge)
            TextButton(onClick = {
                confirming = false
                if (!store.delete(note)) Toast.makeText(context, "Could not delete", Toast.LENGTH_SHORT).show()
            }) { Text("Yes", color = palette.danger) }
            TextButton(onClick = { confirming = false }) { Text("No") }
        } else {
            IconButton(onClick = {
                scope.launch {
                    clipboard.setText(AnnotatedString(store.body(note)))
                    Toast.makeText(context, "Copied", Toast.LENGTH_SHORT).show()
                }
            }) { Icon(Icons.Default.ContentCopy, "Copy body") }
            IconButton(onClick = {
                if (store.clone(note) == null) Toast.makeText(context, "Could not clone", Toast.LENGTH_SHORT).show()
            }) { Icon(Icons.Default.FileCopy, "Clone") }
            IconButton(onClick = { confirming = true }) { Icon(Icons.Default.Delete, "Delete") }
        }
    }
}
