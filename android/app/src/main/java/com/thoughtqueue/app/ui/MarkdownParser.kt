package com.thoughtqueue.app.ui

import com.thoughtqueue.app.store.TaskList

/** A run of inline text with its styling. */
data class InlineSpan(
    val text: String,
    val bold: Boolean = false,
    val italic: Boolean = false,
    val code: Boolean = false,
    val strike: Boolean = false,
    val url: String? = null,
)

/** A block-level markdown element. [line] is the source line index (the same "\n" split as TaskList). */
sealed class MdBlock {
    data class Heading(val level: Int, val text: String) : MdBlock()
    data class Code(val text: String) : MdBlock()
    data class Task(val line: Int, val indent: Int, val checked: Boolean, val text: String) : MdBlock()
    data class Bullet(val indent: Int, val text: String) : MdBlock()
    data class Ordered(val indent: Int, val number: String, val text: String) : MdBlock()
    data class Quote(val text: String) : MdBlock()
    object Rule : MdBlock()
    data class Paragraph(val text: String) : MdBlock()
}

/**
 * A small hand-rolled markdown parser covering headings, bold, italic, strikethrough, inline and
 * fenced code, bullet, ordered and task lists, block quotes, rules and links. Tables and nested
 * emphasis are not supported. Pure so it can be unit tested.
 */
object MarkdownParser {
    private val headingRegex = Regex("""^(#{1,6})[ \t]+(.*)$""")
    private val bulletRegex = Regex("""^([ \t]*)[-*+][ \t]+(.*)$""")
    private val orderedRegex = Regex("""^([ \t]*)(\d{1,9})[.)][ \t]+(.*)$""")
    private val ruleRegex = Regex("""^[ \t]*([-*_])([ \t]*\1){2,}[ \t]*$""")
    private val inlineRegex = Regex(
        """(`[^`\n]+`)|(\*\*[^*\n]+\*\*)|(__[^_\n]+__)|(~~[^~\n]+~~)|(\*[^*\s][^*\n]*\*)|""" +
            """(\b_[^_\s][^_\n]*_\b)|(\[[^\]\n]+\]\([^)\s]+\))|(https?://[^\s<>)]+)""",
    )

    /** Width of leading whitespace in indent levels (a tab or two spaces is one level). */
    private fun indentLevel(ws: String): Int {
        var width = 0
        for (c in ws) width += if (c == '\t') 2 else 1
        return width / 2
    }

    /** Parse a whole body into blocks. Blank lines separate paragraphs and are not emitted. */
    fun parse(body: String): List<MdBlock> {
        val lines = body.split("\n").map { it.removeSuffix("\r") }
        val blocks = ArrayList<MdBlock>()
        var i = 0
        while (i < lines.size) {
            val line = lines[i]
            if (line.trimStart().startsWith("```")) {
                val code = StringBuilder()
                i++
                while (i < lines.size && !lines[i].trimStart().startsWith("```")) {
                    if (code.isNotEmpty()) code.append('\n')
                    code.append(lines[i])
                    i++
                }
                blocks.add(MdBlock.Code(code.toString()))
                i++
                continue
            }
            val task = TaskList.parse(line)
            when {
                line.isBlank() -> {}
                task != null -> blocks.add(MdBlock.Task(i, indentLevel(task.indent), task.checked, task.text))
                headingRegex.matchEntire(line) != null -> {
                    val m = headingRegex.matchEntire(line)!!
                    blocks.add(MdBlock.Heading(m.groupValues[1].length, m.groupValues[2]))
                }
                ruleRegex.matchEntire(line) != null -> blocks.add(MdBlock.Rule)
                line.trimStart().startsWith(">") ->
                    blocks.add(MdBlock.Quote(line.trimStart().removePrefix(">").trim()))
                bulletRegex.matchEntire(line) != null -> {
                    val m = bulletRegex.matchEntire(line)!!
                    blocks.add(MdBlock.Bullet(indentLevel(m.groupValues[1]), m.groupValues[2]))
                }
                orderedRegex.matchEntire(line) != null -> {
                    val m = orderedRegex.matchEntire(line)!!
                    blocks.add(MdBlock.Ordered(indentLevel(m.groupValues[1]), m.groupValues[2], m.groupValues[3]))
                }
                else -> {
                    // Consecutive plain lines join into one paragraph.
                    val last = blocks.lastOrNull()
                    val prevBlank = i == 0 || lines[i - 1].isBlank()
                    if (last is MdBlock.Paragraph && !prevBlank) {
                        blocks[blocks.size - 1] = MdBlock.Paragraph(last.text + " " + line.trim())
                    } else {
                        blocks.add(MdBlock.Paragraph(line.trim()))
                    }
                }
            }
            i++
        }
        return blocks
    }

    /** Split inline text into styled spans. */
    fun inline(text: String): List<InlineSpan> {
        val spans = ArrayList<InlineSpan>()
        var pos = 0
        for (m in inlineRegex.findAll(text)) {
            if (m.range.first > pos) spans.add(InlineSpan(text.substring(pos, m.range.first)))
            val s = m.value
            spans.add(
                when {
                    m.groups[1] != null -> InlineSpan(s.substring(1, s.length - 1), code = true)
                    m.groups[2] != null || m.groups[3] != null -> InlineSpan(s.substring(2, s.length - 2), bold = true)
                    m.groups[4] != null -> InlineSpan(s.substring(2, s.length - 2), strike = true)
                    m.groups[5] != null || m.groups[6] != null -> InlineSpan(s.substring(1, s.length - 1), italic = true)
                    m.groups[7] != null -> {
                        val close = s.indexOf("](")
                        InlineSpan(s.substring(1, close), url = s.substring(close + 2, s.length - 1))
                    }
                    else -> InlineSpan(s, url = s)
                },
            )
            pos = m.range.last + 1
        }
        if (pos < text.length) spans.add(InlineSpan(text.substring(pos)))
        return spans
    }
}
