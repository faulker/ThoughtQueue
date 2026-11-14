package com.thoughtqueue.app.store

/**
 * Decomposes a markdown body into editable rows and reassembles it byte for byte.
 *
 * Every row keeps enough verbatim detail to reproduce its source line exactly. The round trip is
 * guaranteed rather than hoped for: [row] re-serializes its own candidate and falls back to
 * [RowKind.Other] on any mismatch, so `body(rows(s)) == s` holds for every input.
 */

/** The kinds of line the checklist editor models. */
sealed class RowKind {
    data class Task(val task: TaskItem) : RowKind()
    data class Heading(val heading: HeadingItem) : RowKind()

    /** A blank line, kept verbatim (may hold whitespace). */
    data class Blank(val raw: String) : RowKind()

    /** Anything the checklist editor does not model, kept verbatim. */
    data class Other(val raw: String) : RowKind()
}

/** One source line, decomposed far enough to edit and reassemble. */
data class Row(val kind: RowKind, val carriageReturn: Boolean = false) {
    val isTask: Boolean get() = kind is RowKind.Task
    val isBlank: Boolean get() = kind is RowKind.Blank

    /** The editable text of the row, empty for a blank line. */
    val text: String
        get() = when (val k = kind) {
            is RowKind.Task -> k.task.text
            is RowKind.Heading -> k.heading.text
            is RowKind.Blank -> ""
            is RowKind.Other -> k.raw
        }

    val checked: Boolean get() = (kind as? RowKind.Task)?.task?.checked ?: false
}

/** A task line's pieces. [marker] and [gap] are kept as written so an untouched line reproduces itself. */
data class TaskItem(
    val indent: String,
    val bullet: Char,
    /** Whitespace between the bullet and `[`. */
    val spacing: String,
    /** The character between the brackets, verbatim (" ", "x" or "X"). */
    val marker: Char,
    /** The single space or tab after `]`, or "" for a bare `- [ ]`. */
    val gap: String,
    /** Everything after the gap, verbatim. */
    val text: String,
) {
    val checked: Boolean get() = marker == 'x' || marker == 'X'

    /** Copy with the marker set (lowercase `x`); a bare item that has text gains its separator. */
    fun withChecked(on: Boolean): TaskItem {
        val g = if (gap.isEmpty() && text.isNotEmpty()) " " else gap
        return copy(marker = if (on) 'x' else ' ', gap = g)
    }
}

/** An ATX heading line, shown as a section label in the checklist. */
data class HeadingItem(val indent: String, val level: Int, val spacing: String, val text: String)

/** The result of a structural edit: new rows plus where the caret belongs afterwards. */
data class RowEdit(val rows: List<Row>, val focusRow: Int, val focusOffset: Int)

/** Row-level parsing, reassembly and structural edits for checklist notes. */
object TaskRows {
    private val headingRegex = Regex("""^([ \t]*)(#{1,6})([ \t]+)(.*)$""")

    // MARK: Line parsing

    /** Decompose one line (without its newline), guarded by the reassemble-and-compare check. */
    fun row(line: String): Row {
        var content = line
        var cr = false
        if (content.endsWith("\r")) {
            content = content.dropLast(1)
            cr = true
        }
        val candidate = classify(content, cr)
        if (line(candidate) != line) return Row(RowKind.Other(content), cr)
        return candidate
    }

    private fun classify(content: String, cr: Boolean): Row {
        TaskList.taskMatch(content)?.let { m ->
            val markerPos = m.groups[4]!!.range.first
            val afterBracket = markerPos + 2
            val textGroup = m.groups[5]
            val text = textGroup?.value ?: ""
            val gap = if (textGroup == null) {
                content.substring(minOf(afterBracket, content.length))
            } else {
                content.substring(afterBracket, maxOf(afterBracket, textGroup.range.first))
            }
            val task = TaskItem(
                indent = m.groupValues[1],
                bullet = m.groupValues[2][0],
                spacing = m.groupValues[3],
                marker = content[markerPos],
                gap = gap,
                text = text,
            )
            return Row(RowKind.Task(task), cr)
        }
        headingRegex.find(content)?.let { m ->
            val heading = HeadingItem(
                m.groupValues[1], m.groupValues[2].length, m.groupValues[3], m.groupValues[4],
            )
            return Row(RowKind.Heading(heading), cr)
        }
        if (content.all { it == ' ' || it == '\t' }) return Row(RowKind.Blank(content), cr)
        return Row(RowKind.Other(content), cr)
    }

    /** Reassemble one row into its source line (without a newline). */
    fun line(row: Row): String {
        val content = when (val k = row.kind) {
            is RowKind.Task -> k.task.let {
                it.indent + it.bullet + it.spacing + "[" + it.marker + "]" + it.gap + it.text
            }
            is RowKind.Heading -> k.heading.let {
                it.indent + "#".repeat(it.level) + it.spacing + it.text
            }
            is RowKind.Blank -> k.raw
            is RowKind.Other -> k.raw
        }
        return if (row.carriageReturn) content + "\r" else content
    }

    // MARK: Body parsing

    /** Split a body into rows using the same "\n" split as [TaskList.toggle]. */
    fun rows(body: String): List<Row> = body.split("\n").map { row(it) }

    /** Reassemble rows into a body. A trailing newline round-trips as a final blank row. */
    fun body(rows: List<Row>): String = rows.joinToString("\n") { line(it) }

    // MARK: Structural edits

    /**
     * A fresh unchecked, empty task row inheriting indentation, bullet, spacing and line ending
     * from [template], so adding to a `*`-bulleted CRLF list stays consistent.
     */
    fun newTaskRow(template: Row?): Row {
        val k = template?.kind
        if (template != null && k is RowKind.Task) {
            val t = k.task
            return Row(RowKind.Task(TaskItem(t.indent, t.bullet, t.spacing, ' ', " ", "")), template.carriageReturn)
        }
        return Row(
            RowKind.Task(TaskItem("", '-', " ", ' ', " ", "")),
            template?.carriageReturn ?: false,
        )
    }

    /** Insert an empty item below [index]. */
    fun insertingTask(after: Int, rows: List<Row>): RowEdit {
        val updated = rows.toMutableList()
        val template = rows.getOrNull(after) ?: rows.lastOrNull()
        val at = minOf(after + 1, updated.size)
        updated.add(at, newTaskRow(template))
        return RowEdit(updated, at, 0)
    }

    /** Split the item at [index] at [offset]: the row keeps the prefix, a new row takes the suffix. */
    fun splittingTask(index: Int, offset: Int, rows: List<Row>): RowEdit {
        val k = rows.getOrNull(index)?.kind
        if (k !is RowKind.Task) return RowEdit(rows, index, offset)
        val task = k.task
        val updated = rows.toMutableList()
        val clamped = offset.coerceIn(0, task.text.length)
        val suffix = task.text.substring(clamped)
        updated[index] = rows[index].copy(kind = RowKind.Task(task.copy(text = task.text.substring(0, clamped))))
        val fresh = newTaskRow(rows[index])
        val freshTask = (fresh.kind as RowKind.Task).task
        updated.add(index + 1, fresh.copy(kind = RowKind.Task(freshTask.copy(text = suffix))))
        return RowEdit(updated, index + 1, 0)
    }

    /**
     * Delete a row, focusing the end of the previous editable row. Never leaves the body without
     * a task row: deleting the last one substitutes a fresh empty item.
     */
    fun deletingRow(index: Int, rows: List<Row>): RowEdit {
        if (index !in rows.indices) return RowEdit(rows, index, 0)
        val updated = rows.toMutableList()
        updated.removeAt(index)
        if (updated.none { it.isTask }) {
            val at = minOf(index, updated.size)
            updated.add(at, newTaskRow(rows[index]))
            return RowEdit(updated, at, 0)
        }
        val focus = previousEditableIndex(index, updated) ?: nextEditableIndex(index, updated) ?: 0
        return RowEdit(updated, focus, updated[focus].text.length)
    }

    /** Append this row's text to the previous item and delete it; a no-op unless both are tasks. */
    fun mergingRowIntoPrevious(index: Int, rows: List<Row>): RowEdit {
        val cur = rows.getOrNull(index)?.kind
        val prev = rows.getOrNull(index - 1)?.kind
        if (index <= 0 || cur !is RowKind.Task || prev !is RowKind.Task) return RowEdit(rows, index, 0)
        val updated = rows.toMutableList()
        val join = prev.task.text.length
        updated[index - 1] = rows[index - 1].copy(kind = RowKind.Task(prev.task.copy(text = prev.task.text + cur.task.text)))
        updated.removeAt(index)
        return RowEdit(updated, index - 1, join)
    }

    /** Replace the editable text of row [index]. */
    fun settingText(text: String, index: Int, rows: List<Row>): List<Row> {
        val row = rows.getOrNull(index) ?: return rows
        val newKind = when (val k = row.kind) {
            is RowKind.Task -> {
                val gap = if (k.task.gap.isEmpty() && text.isNotEmpty()) " " else k.task.gap
                RowKind.Task(k.task.copy(text = text, gap = gap))
            }
            is RowKind.Heading -> RowKind.Heading(k.heading.copy(text = text))
            is RowKind.Blank -> return rows
            is RowKind.Other -> RowKind.Other(text)
        }
        return rows.toMutableList().also { it[index] = row.copy(kind = newKind) }
    }

    /** Set the checked state of task row [index]. */
    fun settingChecked(on: Boolean, index: Int, rows: List<Row>): List<Row> {
        val row = rows.getOrNull(index) ?: return rows
        val k = row.kind as? RowKind.Task ?: return rows
        return rows.toMutableList().also { it[index] = row.copy(kind = RowKind.Task(k.task.withChecked(on))) }
    }

    /** Where "+ Add item" appends: after the last non-blank row, so trailing blanks stay last. */
    fun appendAnchor(rows: List<Row>): Int {
        for (i in rows.indices.reversed()) if (!rows[i].isBlank) return i
        return rows.size - 1
    }

    /** The nearest editable row before [index], or null. */
    fun previousEditableIndex(index: Int, rows: List<Row>): Int? =
        (minOf(index, rows.size) - 1 downTo 0).firstOrNull { rows[it].isTask || !rows[it].isBlank }

    /** The nearest editable row at or after [index], or null. */
    fun nextEditableIndex(index: Int, rows: List<Row>): Int? =
        rows.indices.filter { it >= index }.firstOrNull { !rows[it].isBlank }
}
