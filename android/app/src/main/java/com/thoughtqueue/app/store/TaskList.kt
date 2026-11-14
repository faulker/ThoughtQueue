package com.thoughtqueue.app.store

/**
 * Pure parsing and rewriting of GFM task lines (`- [ ] milk` / `- [x] eggs`).
 *
 * A checklist is not a file format of its own: it is an ordinary markdown note whose lines
 * happen to be task lines. Everything here is a pure function over strings, so it is directly
 * unit-testable. The rewriters are surgical: only the single character between the brackets is
 * replaced, so indentation, bullet, spacing, trailing content and CRLF endings survive.
 */
object TaskList {

    /** The prefix a brand-new item is written with. */
    const val NEW_ITEM_PREFIX = "- [ ] "

    /** A parsed task line, with each piece kept verbatim so it can be reassembled losslessly. */
    data class Line(
        val indent: String,
        val bullet: Char,
        val spacing: String,
        val checked: Boolean,
        val text: String,
    )

    /** What the Return key should do when pressed at the end of a line. */
    sealed class ReturnAction {
        /** Not a list line: insert a plain newline. */
        object Pass : ReturnAction()

        /** Continue the list by inserting a newline plus this prefix. */
        data class ContinueList(val prefix: String) : ReturnAction()

        /** The item is empty, so end the list by wiping the marker instead of continuing. */
        object ClearMarker : ReturnAction()
    }

    /** Result of applying Return to a text: the new text and where the caret goes. */
    data class TextEdit(val text: String, val cursor: Int)

    /**
     * Matches a task line. Group 1 indent, 2 bullet, 3 spacing, 4 marker, 5 trailing content.
     * The trailing group is optional so a bare `- [ ]` still parses.
     */
    private val taskRegex = Regex("""^([ \t]*)([-*+])([ \t]+)\[([ xX])\](?:[ \t](.*)|[ \t]*)$""")

    private val bulletRegex = Regex("""^([-*+])([ \t]+)(.*)$""")

    /** An ordered list item. Group 1 indent, 2 number, 3 delimiter, 4 spacing, 5 content. */
    private val orderedRegex = Regex("""^([ \t]*)(\d{1,9})([.)])([ \t]+)(.*)$""")

    /** A plain bullet item. Group 1 indent, 2 bullet, 3 spacing, 4 content. */
    private val listBulletRegex = Regex("""^([ \t]*)([-*+])([ \t]+)(.*)$""")

    // MARK: Parsing

    /** Parse a single line, or null when it is not a task line. */
    fun parse(line: String): Line? {
        val m = taskRegex.find(line) ?: return null
        return Line(
            indent = m.groupValues[1],
            bullet = m.groupValues[2][0],
            spacing = m.groupValues[3],
            checked = m.groupValues[4].lowercase() == "x",
            text = m.groups[5]?.value ?: "",
        )
    }

    /** True when [line] is a task line. */
    fun isTaskLine(line: String): Boolean = taskRegex.find(line) != null

    /** The raw regex match for a task line, used by the row decomposition. */
    internal fun taskMatch(line: String): MatchResult? = taskRegex.find(line)

    // MARK: Rewriting

    /**
     * Flip one line's marker. Returns null when [line] is not a task line. Uppercase `[X]` is
     * recognized on the way in; lowercase `x` is always written.
     */
    fun toggled(line: String): String? {
        val m = taskMatch(line) ?: return null
        val marker = m.groups[4]!!.range.first
        val wasChecked = line[marker] == 'x' || line[marker] == 'X'
        return line.substring(0, marker) + (if (wasChecked) " " else "x") + line.substring(marker + 1)
    }

    /** Turn a non-task line into an unchecked task line, preserving indentation. */
    private fun promoted(line: String): String {
        val indent = line.takeWhile { it == ' ' || it == '\t' }
        val rest = line.substring(indent.length)
        if (rest.isEmpty()) return indent + NEW_ITEM_PREFIX
        val m = bulletRegex.find(rest)
        if (m != null) {
            return indent + m.groupValues[1] + m.groupValues[2] + "[ ] " + m.groupValues[3]
        }
        return indent + NEW_ITEM_PREFIX + rest
    }

    // MARK: Body-level operations

    /**
     * Flip the task on source line [lineIndex] of a whole markdown body. Splits and joins on
     * "\n" so every untouched line round-trips unchanged. Returns null when the index is out of
     * range or that line is not a task line.
     */
    fun toggle(body: String, lineIndex: Int): String? {
        val lines = body.split("\n").toMutableList()
        if (lineIndex !in lines.indices) return null
        lines[lineIndex] = toggled(lines[lineIndex]) ?: return null
        return lines.joinToString("\n")
    }

    /** Checked state of the task on [lineIndex], or null when it is not a task line. */
    fun isChecked(body: String, lineIndex: Int): Boolean? {
        val lines = body.split("\n")
        if (lineIndex !in lines.indices) return null
        return parse(lines[lineIndex])?.checked
    }

    /**
     * Toggle line [lineIndex] if it is already a task, otherwise turn it into one. Returns null
     * only when the index is out of range.
     */
    fun toggleOrPromote(body: String, lineIndex: Int): String? {
        val lines = body.split("\n").toMutableList()
        if (lineIndex !in lines.indices) return null
        lines[lineIndex] = toggled(lines[lineIndex]) ?: promoted(lines[lineIndex])
        return lines.joinToString("\n")
    }

    // MARK: Typing

    /**
     * What Return should do at the end of [line]. Task items, plain bullets and ordered items
     * continue with their indentation and spacing kept; a continued task starts unchecked and an
     * ordered item's number is incremented. An empty item ends the list.
     */
    fun returnAction(line: String): ReturnAction {
        parse(line)?.let { task ->
            if (task.text.isBlank()) return ReturnAction.ClearMarker
            return ReturnAction.ContinueList(task.indent + task.bullet + task.spacing + "[ ] ")
        }
        orderedRegex.find(line)?.let { m ->
            val number = m.groupValues[2].toIntOrNull()
            if (number != null) {
                if (m.groupValues[5].isBlank()) return ReturnAction.ClearMarker
                return ReturnAction.ContinueList(
                    m.groupValues[1] + (number + 1) + m.groupValues[3] + m.groupValues[4],
                )
            }
        }
        listBulletRegex.find(line)?.let { m ->
            if (m.groupValues[4].isBlank()) return ReturnAction.ClearMarker
            return ReturnAction.ContinueList(m.groupValues[1] + m.groupValues[2] + m.groupValues[3])
        }
        return ReturnAction.Pass
    }

    /**
     * Apply Return with a collapsed caret at [cursor] in [text]. Returns the edited text and
     * caret, or null when Return should insert a plain newline (not a list line, or the caret is
     * mid-item). Mirrors the desktop editor: continue the list, or wipe an empty marker in place.
     */
    fun applyReturn(text: String, cursor: Int): TextEdit? {
        if (cursor < 0 || cursor > text.length) return null
        val lineStart = if (cursor == 0) 0 else text.lastIndexOf('\n', cursor - 1) + 1
        val newline = text.indexOf('\n', cursor)
        var contentEnd = if (newline < 0) text.length else newline
        if (contentEnd > lineStart && text[contentEnd - 1] == '\r') contentEnd -= 1
        if (cursor < contentEnd) return null
        val line = text.substring(lineStart, contentEnd)
        return when (val action = returnAction(line)) {
            ReturnAction.Pass -> null
            is ReturnAction.ContinueList -> TextEdit(
                text.substring(0, cursor) + "\n" + action.prefix + text.substring(cursor),
                cursor + 1 + action.prefix.length,
            )
            ReturnAction.ClearMarker -> TextEdit(
                text.substring(0, lineStart) + text.substring(contentEnd),
                lineStart,
            )
        }
    }

    // MARK: Classification

    /**
     * True when [markdown] reads as a checklist rather than prose: at least one task line, and
     * every line that is neither blank nor an ATX heading is a task line. Only used to decide
     * whether to offer "Edit as Checklist"; the document type itself is never inferred.
     */
    fun isChecklist(markdown: String): Boolean {
        var sawTask = false
        for (line in markdown.split("\n")) {
            val trimmed = line.trim()
            if (trimmed.isEmpty()) continue
            if (isTaskLine(line)) { sawTask = true; continue }
            if (trimmed.startsWith("#")) continue
            return false
        }
        return sawTask
    }
}
