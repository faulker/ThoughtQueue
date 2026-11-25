package com.thoughtqueue.app.ui

import android.widget.Toast
import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
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
import androidx.compose.material.icons.filled.Check
import androidx.compose.material.icons.filled.ContentCopy
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.FileCopy
import androidx.compose.material.icons.filled.Folder
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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

/** How the main list is arranged. */
enum class ListMode {
    /** Grouped under category headers (the default). */
    BY_CATEGORY,

    /** One flat list, most recently edited first (the Home button). */
    RECENT,
}

/**
 * The popover equivalent: a searchable list of notes (archived folders hidden) with copy, clone
 * and inline-confirmed delete per row, plus "+ Add" (markdown) and "+ List" (checklist). [mode]
 * picks grouped-by-category or recent; the hamburger and Home buttons switch between them.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NotesListScreen(
    app: TqApp,
    mode: ListMode,
    onModeChange: (ListMode) -> Unit,
    onOpenNote: (String) -> Unit,
    onCategories: () -> Unit,
    onSettings: () -> Unit,
    onConflicts: () -> Unit,
) {
    val store = app.store
    val context = LocalContext.current
    val conflicts by app.sync.conflicts.collectAsState()
    val palette = LocalPalette.current
    val notes = storeQuery(store, emptyList()) { visibleNotes() }
    val groups = storeQuery(store, emptyList()) { visibleGroups() }
    val categories = storeQuery(store, emptyList()) { categories() }
    var query by remember { mutableStateOf("") }
    val shown = FuzzySearch.rank(notes, query)
    val shownGroups = groups
        .map { (category, members) -> category to FuzzySearch.rank(members, query) }
        .filter { it.second.isNotEmpty() }

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
                    IconButton(onClick = { onModeChange(ListMode.RECENT) }) {
                        Icon(Icons.Default.Home, "Recent notes", tint = if (mode == ListMode.RECENT) palette.accent else palette.iconStroke)
                    }
                    IconButton(onClick = { onModeChange(ListMode.BY_CATEGORY) }) {
                        Icon(Icons.Default.Menu, "Notes by category", tint = if (mode == ListMode.BY_CATEGORY) palette.accent else palette.iconStroke)
                    }
                    IconButton(onClick = onCategories) { Icon(Icons.Default.Folder, "Categories") }
                    IconButton(onClick = onSettings) { Icon(Icons.Default.Settings, "Settings") }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            if (conflicts.isNotEmpty()) ConflictBanner(conflicts.size, onConflicts)
            UpdateBanner(app)
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
                    color = palette.textSecondary,
                )
            }
            /** Open [note] by its store-relative key. */
            fun open(note: Note) {
                NoteMetadataStore.key(note.file, store.root)?.let(onOpenNote)
            }
            LazyColumn(Modifier.fillMaxSize()) {
                if (mode == ListMode.RECENT) {
                    items(shown, key = { it.file.path }) { note ->
                        NoteRow(app, note, categories, showCategory = true, onOpen = { open(note) })
                    }
                } else {
                    for ((category, members) in shownGroups) {
                        item(key = "h:" + (category ?: "\u0000")) {
                            Text(
                                category ?: Note.UNCATEGORIZED,
                                style = MaterialTheme.typography.titleSmall,
                                color = palette.accentBorder,
                                modifier = Modifier.padding(start = 16.dp, end = 16.dp, top = 16.dp, bottom = 4.dp),
                            )
                        }
                        items(members, key = { it.file.path }) { note ->
                            NoteRow(app, note, categories, showCategory = false, onOpen = { open(note) })
                        }
                    }
                }
            }
        }
    }
}

/**
 * One list row. Actions are copy body, clone and delete; delete swaps the action strip for an
 * inline "Delete?" prompt that cancels itself after a few seconds (no modal dialog). Long-press
 * opens a "Move to category" menu listing Uncategorized plus [categories]. The category pill is
 * shown only when [showCategory] is set (the grouped view already has a header).
 */
@OptIn(ExperimentalFoundationApi::class)
@Composable
private fun NoteRow(app: TqApp, note: Note, categories: List<String>, showCategory: Boolean, onOpen: () -> Unit) {
    val store = app.store
    val clipboard = LocalClipboardManager.current
    val context = LocalContext.current
    val palette = LocalPalette.current
    val scope = rememberCoroutineScope()
    var confirming by remember { mutableStateOf(false) }
    var moveMenuOpen by remember { mutableStateOf(false) }

    LaunchedEffect(confirming) {
        if (confirming) {
            delay(4000)
            confirming = false
        }
    }

    Row(
        Modifier.fillMaxWidth()
            .combinedClickable(onClick = onOpen, onLongClick = { moveMenuOpen = true })
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(Modifier.weight(1f)) {
            Text(note.title, style = MaterialTheme.typography.titleMedium, maxLines = 1, overflow = TextOverflow.Ellipsis)
            if (showCategory) {
                Spacer(Modifier.padding(top = 2.dp))
                CategoryPill(note.categoryDisplay, tintIndex(note.category))
            }
            DropdownMenu(expanded = moveMenuOpen, onDismissRequest = { moveMenuOpen = false }) {
                Text(
                    "Move to category",
                    style = MaterialTheme.typography.labelMedium,
                    color = palette.textSecondary,
                    modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp),
                )
                for (target in listOf<String?>(null) + categories) {
                    val isCurrent = target == note.category
                    DropdownMenuItem(
                        text = { Text(target ?: Note.UNCATEGORIZED) },
                        leadingIcon = { if (isCurrent) Icon(Icons.Default.Check, "Current category") },
                        enabled = !isCurrent,
                        onClick = {
                            moveMenuOpen = false
                            if (store.move(note, target) == null) {
                                Toast.makeText(context, "Could not move note", Toast.LENGTH_SHORT).show()
                            }
                        },
                    )
                }
            }
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
