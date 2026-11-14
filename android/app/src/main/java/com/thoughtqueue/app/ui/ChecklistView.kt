package com.thoughtqueue.app.ui

import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Checkbox
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.focus.FocusRequester
import androidx.compose.ui.focus.focusRequester
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.input.key.KeyEventType
import androidx.compose.ui.input.key.key
import androidx.compose.ui.input.key.onPreviewKeyEvent
import androidx.compose.ui.input.key.type
import androidx.compose.ui.text.TextRange
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.TextFieldValue
import androidx.compose.ui.text.style.TextDecoration
import androidx.compose.ui.unit.dp
import com.thoughtqueue.app.store.Row as TqRow
import com.thoughtqueue.app.store.RowKind
import com.thoughtqueue.app.store.TaskRows
import com.thoughtqueue.app.ui.theme.LocalPalette

/** Lists longer than this fall back to rendered markdown, as on the desktop. */
const val CHECKLIST_MAX_ROWS = 400

/**
 * Always-live checklist: each item is its own text field with a checkbox, never a view/edit
 * toggle. The body string stays the single source of truth; every edit goes through [TaskRows]
 * so untouched lines (CRLF included) are written back byte for byte.
 */
@Composable
fun ChecklistView(body: String, onBodyChange: (String) -> Unit, modifier: Modifier = Modifier) {
    val rows = TaskRows.rows(body)
    var focus by remember { mutableStateOf<Pair<Int, Int>?>(null) }

    /** Apply a structural edit and move the caret where it says. */
    fun apply(edit: com.thoughtqueue.app.store.RowEdit) {
        onBodyChange(TaskRows.body(edit.rows))
        focus = edit.focusRow to edit.focusOffset
    }

    LazyColumn(modifier.padding(horizontal = 8.dp)) {
        itemsIndexed(rows) { index, row ->
            if (row.isBlank) {
                Spacer(Modifier.height(0.dp))
            } else {
                ChecklistRow(
                    row = row,
                    focusOffset = focus?.takeIf { it.first == index }?.second,
                    onFocusConsumed = { focus = null },
                    onChecked = { onBodyChange(TaskRows.body(TaskRows.settingChecked(it, index, rows))) },
                    onText = { onBodyChange(TaskRows.body(TaskRows.settingText(it, index, rows))) },
                    onEnter = { offset ->
                        if (row.isTask) apply(TaskRows.splittingTask(index, offset, rows))
                        else apply(TaskRows.insertingTask(index, rows))
                    },
                    onBackspaceAtStart = {
                        if (row.text.isEmpty()) apply(TaskRows.deletingRow(index, rows))
                        else apply(TaskRows.mergingRowIntoPrevious(index, rows))
                    },
                    onRemove = { apply(TaskRows.deletingRow(index, rows)) },
                )
            }
        }
        item {
            TextButton(onClick = { apply(TaskRows.insertingTask(TaskRows.appendAnchor(rows), rows)) }) {
                Text("+ Add item")
            }
        }
    }
}

/** One checklist line: optional checkbox, an editable field, and a remove button. */
@Composable
private fun ChecklistRow(
    row: TqRow,
    focusOffset: Int?,
    onFocusConsumed: () -> Unit,
    onChecked: (Boolean) -> Unit,
    onText: (String) -> Unit,
    onEnter: (Int) -> Unit,
    onBackspaceAtStart: () -> Unit,
    onRemove: () -> Unit,
) {
    val palette = LocalPalette.current
    val requester = remember { FocusRequester() }
    var field by remember { mutableStateOf(TextFieldValue(row.text)) }
    // Rows shift when items are inserted or removed, so re-sync the text from the model.
    if (field.text != row.text) field = field.copy(text = row.text, selection = TextRange(row.text.length))

    LaunchedEffect(focusOffset) {
        if (focusOffset != null) {
            requester.requestFocus()
            field = field.copy(selection = TextRange(focusOffset.coerceIn(0, field.text.length)))
            onFocusConsumed()
        }
    }

    val isHeading = row.kind is RowKind.Heading
    Row(Modifier.fillMaxWidth(), verticalAlignment = Alignment.CenterVertically) {
        if (row.isTask) {
            Checkbox(checked = row.checked, onCheckedChange = onChecked)
        } else {
            Spacer(Modifier.padding(start = 16.dp))
        }
        BasicTextField(
            value = field,
            onValueChange = { field = it; if (it.text != row.text) onText(it.text) },
            textStyle = (if (isHeading) MaterialTheme.typography.titleMedium else MaterialTheme.typography.bodyLarge)
                .copy(
                    color = if (row.checked) palette.textSecondary else palette.textPrimary,
                    textDecoration = if (row.checked) TextDecoration.LineThrough else null,
                ),
            cursorBrush = SolidColor(palette.accent),
            singleLine = true,
            keyboardOptions = KeyboardOptions(imeAction = ImeAction.Next),
            keyboardActions = KeyboardActions(onNext = { onEnter(field.selection.start) }),
            modifier = Modifier
                .weight(1f)
                .padding(vertical = 10.dp)
                .focusRequester(requester)
                .onPreviewKeyEvent { event ->
                    val atStart = field.selection.collapsed && field.selection.start == 0
                    if (event.type == KeyEventType.KeyDown && event.key == Key.Backspace && atStart && row.isTask) {
                        onBackspaceAtStart()
                        true
                    } else false
                },
        )
        IconButton(onClick = onRemove) { Icon(Icons.Default.Close, "Remove item", tint = palette.textSecondary) }
    }
}
