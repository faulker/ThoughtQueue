package com.thoughtqueue.app.ui

import android.widget.Toast
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Edit
import androidx.compose.material.icons.filled.Home
import androidx.compose.material.icons.filled.Menu
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
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
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.TqApp
import com.thoughtqueue.app.prefs.EditMode
import com.thoughtqueue.app.store.Note
import com.thoughtqueue.app.store.NoteDocType
import com.thoughtqueue.app.store.NoteStore
import com.thoughtqueue.app.store.TaskList
import com.thoughtqueue.app.ui.theme.LocalPalette
import kotlinx.coroutines.delay
import java.io.File

/** Debounce before an edit is written to disk. */
private const val AUTOSAVE_DELAY_MS = 600L

/**
 * The note screen. Resolves [path] (store-relative) to a note and shows [NoteEditor], or a short
 * message when the file is gone.
 */
@Composable
fun NoteScreen(app: TqApp, path: String, onBack: () -> Unit, onNotesList: () -> Unit, onHome: () -> Unit) {
    val initial = remember(path) { Note.from(File(app.store.root, path), app.store.root) }
    if (initial == null) {
        Scaffold { padding ->
            Column(Modifier.padding(padding).padding(16.dp)) {
                Text("This note no longer exists.")
                TextButton(onClick = onBack) { Text("Back") }
            }
        }
    } else {
        NoteEditor(app, initial, onBack, onNotesList, onHome)
    }
}

/**
 * Editable title, category dropdown (with inline new category), rendered/raw toggle, debounced
 * autosave, list continuation on Enter, and the checklist presentation for `.checklist` notes.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun NoteEditor(
    app: TqApp,
    initial: Note,
    onBack: () -> Unit,
    onNotesList: () -> Unit,
    onHome: () -> Unit,
) {
    val store = app.store
    val palette = LocalPalette.current
    val defaultMode by app.prefs.editMode.collectAsState()
    val version by store.changes.collectAsState()

    var note by remember { mutableStateOf(initial) }
    var title by remember { mutableStateOf(initial.title) }
    val diskBody = remember { store.body(initial) }
    var field by remember { mutableStateOf(TextFieldValue(diskBody)) }
    var lastSaved by remember { mutableStateOf(diskBody) }
    // A brand-new empty note opens raw so the keyboard is ready; otherwise follow the preference.
    var raw by rememberSaveable { mutableStateOf(diskBody.isEmpty() || defaultMode == EditMode.RAW) }
    var menuOpen by remember { mutableStateOf(false) }
    var creatingCategory by remember { mutableStateOf(false) }
    var confirmingDelete by remember { mutableStateOf(false) }
    val context = LocalContext.current

    val docType = remember(note, version) { store.docType(note) }
    val categories = storeQuery(store, emptyList()) { categories() }
    val body = field.text

    /** Write the body now if it has unsaved changes. */
    fun saveNow() {
        if (field.text != lastSaved && store.updateBody(note, field.text)) lastSaved = field.text
    }

    /** Replace the body from a structural edit (checklist, task toggle), keeping the caret in range. */
    fun setBody(text: String) {
        field = field.copy(text = text, selection = TextRange(minOf(field.selection.start, text.length)))
    }

    LaunchedEffect(field.text) {
        if (field.text != lastSaved) {
            delay(AUTOSAVE_DELAY_MS)
            saveNow()
        }
    }
    DisposableEffect(Unit) { onDispose { saveNow() } }

    // Pick up external changes (sync, another app) only when there are no unsaved local edits.
    // A rename or category move posts its change before `note` is swapped, so a missing file is skipped.
    LaunchedEffect(version) {
        if (note.file.exists() && field.text == lastSaved) {
            val onDisk = store.body(note)
            if (onDisk != lastSaved) {
                lastSaved = onDisk
                field = TextFieldValue(onDisk)
            }
        }
    }

    /** Rename the file to match the title field, flushing the body first so it moves with it. */
    fun commitTitle() {
        val wanted = title.trim()
        if (!NoteStore.shouldRename(wanted, note.title)) {
            title = note.title
            return
        }
        saveNow()
        val renamed = store.rename(note, wanted)
        if (renamed != null) { note = renamed; title = renamed.title } else title = note.title
    }

    /** Move the note to [category] (null is Uncategorized), flushing the body first. */
    fun moveTo(category: String?) {
        saveNow()
        store.move(note, category)?.let { note = it }
    }

    /** Delete the note and leave the screen. The dispose-time save is a no-op once the file is gone. */
    fun deleteNote() {
        confirmingDelete = false
        if (store.delete(note)) onBack() else Toast.makeText(context, "Could not delete", Toast.LENGTH_SHORT).show()
    }

    if (confirmingDelete) {
        AlertDialog(
            onDismissRequest = { confirmingDelete = false },
            title = { Text("Delete note?") },
            text = { Text("\"${note.title}\" will be permanently deleted.") },
            confirmButton = {
                TextButton(onClick = ::deleteNote) { Text("Delete", color = palette.danger) }
            },
            dismissButton = {
                TextButton(onClick = { confirmingDelete = false }) { Text("Cancel") }
            },
        )
    }

    Scaffold(
        topBar = {
            TopAppBar(
                navigationIcon = { BackButton(onBack) },
                title = {
                    BasicTextField(
                        value = title,
                        onValueChange = { title = it },
                        singleLine = true,
                        textStyle = MaterialTheme.typography.titleLarge.copy(color = palette.textPrimary),
                        cursorBrush = SolidColor(palette.accent),
                        keyboardOptions = KeyboardOptions(imeAction = ImeAction.Done),
                        keyboardActions = KeyboardActions(onDone = { commitTitle() }),
                        modifier = Modifier.fillMaxWidth().onFocusChanged { if (!it.isFocused) commitTitle() },
                    )
                },
                actions = {
                    IconButton(onClick = onHome) { Icon(Icons.Default.Home, "Recent notes") }
                    IconButton(onClick = onNotesList) { Icon(Icons.Default.Menu, "Notes by category") }
                    if (docType == NoteDocType.MARKDOWN) {
                        IconButton(onClick = { raw = !raw }) {
                            Icon(if (raw) Icons.Default.Visibility else Icons.Default.Edit, if (raw) "Rendered view" else "Edit raw")
                        }
                    }
                    IconButton(onClick = { menuOpen = true }) { Icon(Icons.Default.MoreVert, "More") }
                    DropdownMenu(expanded = menuOpen, onDismissRequest = { menuOpen = false }) {
                        if (docType == NoteDocType.CHECKLIST) {
                            DropdownMenuItem(text = { Text("Edit as Markdown") }, onClick = {
                                menuOpen = false
                                store.setDocType(NoteDocType.MARKDOWN, note)
                                raw = true
                            })
                        } else if (TaskList.isChecklist(body)) {
                            DropdownMenuItem(text = { Text("Edit as Checklist") }, onClick = {
                                menuOpen = false
                                saveNow()
                                store.setDocType(NoteDocType.CHECKLIST, note)
                            })
                        }
                        DropdownMenuItem(text = { Text("Delete note", color = palette.danger) }, onClick = {
                            menuOpen = false
                            confirmingDelete = true
                        })
                    }
                },
            )
        },
    ) { padding ->
        Column(Modifier.padding(padding).fillMaxSize()) {
            CategoryRow(
                current = note.category,
                categories = categories,
                creating = creatingCategory,
                onStartCreating = { creatingCategory = true },
                onCancelCreating = { creatingCategory = false },
                onSelect = { moveTo(it) },
                onCreate = { name ->
                    creatingCategory = false
                    if (store.createCategory(name)) moveTo(NoteStore.sanitizeCategory(name))
                },
            )
            val useChecklist = docType == NoteDocType.CHECKLIST && body.split("\n").size <= CHECKLIST_MAX_ROWS
            when {
                useChecklist -> ChecklistView(body, ::setBody, Modifier.fillMaxSize())
                raw && docType == NoteDocType.MARKDOWN -> RawEditor(field, { field = it }, Modifier.fillMaxSize())
                else -> MarkdownView(
                    body,
                    onToggleTask = { line -> TaskList.toggle(body, line)?.let(::setBody) },
                    modifier = Modifier.fillMaxSize(),
                )
            }
        }
    }
}

/**
 * The raw markdown editor. Pressing Enter at the end of a list line continues the list (or ends
 * it on an empty item), by recognizing a freshly inserted newline and handing it to
 * [TaskList.applyReturn].
 */
@Composable
private fun RawEditor(value: TextFieldValue, onChange: (TextFieldValue) -> Unit, modifier: Modifier) {
    val palette = LocalPalette.current
    BasicTextField(
        value = value,
        onValueChange = { new ->
            val old = value
            val p = new.selection.start
            val insertedNewline = new.text.length == old.text.length + 1 &&
                new.selection.collapsed && old.selection.collapsed &&
                p >= 1 && new.text[p - 1] == '\n' && p - 1 == old.selection.start &&
                new.text.removeRange(p - 1, p) == old.text
            val edit = if (insertedNewline) TaskList.applyReturn(old.text, old.selection.start) else null
            if (edit != null) onChange(TextFieldValue(edit.text, TextRange(edit.cursor))) else onChange(new)
        },
        textStyle = MaterialTheme.typography.bodyLarge.copy(color = palette.textPrimary),
        cursorBrush = SolidColor(palette.accent),
        modifier = modifier.padding(16.dp),
    )
}

/** Category dropdown with an inline "New category" field that replaces it while creating. */
@Composable
private fun CategoryRow(
    current: String?,
    categories: List<String>,
    creating: Boolean,
    onStartCreating: () -> Unit,
    onCancelCreating: () -> Unit,
    onSelect: (String?) -> Unit,
    onCreate: (String) -> Unit,
) {
    var open by remember { mutableStateOf(false) }
    var newName by remember { mutableStateOf("") }
    Row(
        Modifier.fillMaxWidth().padding(horizontal = 16.dp),
        verticalAlignment = Alignment.CenterVertically,
        horizontalArrangement = Arrangement.spacedBy(8.dp),
    ) {
        if (creating) {
            OutlinedTextField(
                value = newName,
                onValueChange = { newName = it },
                label = { Text("New category") },
                singleLine = true,
                modifier = Modifier.weight(1f),
            )
            TextButton(onClick = { onCreate(newName); newName = "" }, enabled = newName.isNotBlank()) { Text("Add") }
            TextButton(onClick = { onCancelCreating(); newName = "" }) { Text("Cancel") }
        } else {
            Text("Category", style = MaterialTheme.typography.labelLarge)
            TextButton(onClick = { open = true }) {
                Text(current ?: Note.UNCATEGORIZED)
                Icon(Icons.Default.ArrowDropDown, null)
            }
            DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
                DropdownMenuItem(text = { Text(Note.UNCATEGORIZED) }, onClick = { open = false; onSelect(null) })
                for (name in categories) {
                    DropdownMenuItem(text = { Text(name) }, onClick = { open = false; onSelect(name) })
                }
                DropdownMenuItem(text = { Text("New category…") }, onClick = { open = false; onStartCreating() })
            }
        }
    }
}
