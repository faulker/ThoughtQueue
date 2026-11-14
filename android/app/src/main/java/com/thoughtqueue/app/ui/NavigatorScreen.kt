package com.thoughtqueue.app.ui

import androidx.compose.foundation.ExperimentalFoundationApi
import androidx.compose.foundation.combinedClickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Archive
import androidx.compose.material.icons.filled.Star
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.store.FuzzySearch
import com.thoughtqueue.app.store.Note
import com.thoughtqueue.app.store.NoteMetadataStore
import com.thoughtqueue.app.ui.theme.LocalPalette

/** One category section of the navigator. */
private data class NavGroup(val category: String?, val archived: Boolean, val notes: List<Note>)

/**
 * Navigator: every note grouped by category, archived folders last under a dimmed header with an
 * archive glyph, filtered by fuzzy search. Tap opens a note; long-press offers to set or unset the
 * working document.
 */
@OptIn(ExperimentalMaterial3Api::class, ExperimentalFoundationApi::class)
@Composable
fun NavigatorScreen(app: TqApp, onBack: () -> Unit, onOpenNote: (String) -> Unit) {
    val store = app.store
    val palette = LocalPalette.current
    val groups = storeQuery(store, emptyList()) {
        navigatorCategories().map { NavGroup(it, isArchived(it), notes(it)) }
    }
    val workingPath = storeQuery(store, null as String?) { workingDocumentPath }
    var query by remember { mutableStateOf("") }
    var menuFor by remember { mutableStateOf<String?>(null) }

    Scaffold(topBar = { TopAppBar(title = { Text("Notes") }, navigationIcon = { BackButton(onBack) }) }) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            SearchField(query, { query = it }, Modifier.padding(horizontal = 16.dp, vertical = 8.dp))
            LazyColumn(Modifier.fillMaxSize()) {
                for (group in groups) {
                    val ranked = FuzzySearch.rank(group.notes, query)
                    if (query.isNotBlank() && ranked.isEmpty()) continue
                    item(key = "h:" + (group.category ?: "\u0000")) {
                        Row(
                            Modifier.fillMaxWidth().padding(horizontal = 16.dp, vertical = 8.dp).alpha(if (group.archived) 0.5f else 1f),
                            verticalAlignment = Alignment.CenterVertically,
                            horizontalArrangement = Arrangement.spacedBy(6.dp),
                        ) {
                            if (group.archived) Icon(Icons.Default.Archive, "Archived", tint = palette.iconStroke)
                            Text(
                                group.category ?: Note.UNCATEGORIZED,
                                style = MaterialTheme.typography.titleSmall,
                                color = palette.accentBorder,
                            )
                        }
                    }
                    for (note in ranked) {
                        val key = NoteMetadataStore.key(note.file, store.root) ?: continue
                        item(key = "n:$key") {
                            val isWorking = workingPath == key
                            Row(
                                Modifier.fillMaxWidth()
                                    .combinedClickable(onClick = { onOpenNote(key) }, onLongClick = { menuFor = key })
                                    .padding(horizontal = 32.dp, vertical = 12.dp)
                                    .alpha(if (group.archived) 0.5f else 1f),
                                verticalAlignment = Alignment.CenterVertically,
                                horizontalArrangement = Arrangement.spacedBy(6.dp),
                            ) {
                                if (isWorking) Icon(Icons.Default.Star, "Working document", tint = palette.accent)
                                Text(note.title, style = MaterialTheme.typography.bodyLarge)
                                DropdownMenu(expanded = menuFor == key, onDismissRequest = { menuFor = null }) {
                                    DropdownMenuItem(
                                        text = { Text(if (isWorking) "Unset working document" else "Set as working document") },
                                        onClick = {
                                            menuFor = null
                                            store.setWorkingDocument(if (isWorking) null else note)
                                        },
                                    )
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}
