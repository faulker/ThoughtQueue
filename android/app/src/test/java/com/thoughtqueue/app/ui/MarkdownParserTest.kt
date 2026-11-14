package com.thoughtqueue.app.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Parser coverage for the hand-rolled markdown renderer. */
class MarkdownParserTest {
    @Test fun blocksAndTaskSourceLines() {
        val blocks = MarkdownParser.parse("# T\n\ntext\nmore\n- [ ] a\n  - [x] b\n- item\n1. one\n> q\n---\n```\ncode\n```")
        assertEquals(MdBlock.Heading(1, "T"), blocks[0])
        assertEquals(MdBlock.Paragraph("text more"), blocks[1])
        assertEquals(MdBlock.Task(4, 0, false, "a"), blocks[2])
        assertEquals(MdBlock.Task(5, 1, true, "b"), blocks[3])
        assertEquals(MdBlock.Bullet(0, "item"), blocks[4])
        assertEquals(MdBlock.Ordered(0, "1", "one"), blocks[5])
        assertEquals(MdBlock.Quote("q"), blocks[6])
        assertEquals(MdBlock.Rule, blocks[7])
        assertEquals(MdBlock.Code("code"), blocks[8])
    }

    @Test fun crlfBodiesParseLikeLf() {
        assertEquals(MarkdownParser.parse("# a\n- [ ] b"), MarkdownParser.parse("# a\r\n- [ ] b"))
    }

    @Test fun inlineStyles() {
        val spans = MarkdownParser.inline("a **b** *c* `d` ~~e~~ [f](http://x.y) end")
        assertTrue(spans.any { it.text == "b" && it.bold })
        assertTrue(spans.any { it.text == "c" && it.italic })
        assertTrue(spans.any { it.text == "d" && it.code })
        assertTrue(spans.any { it.text == "e" && it.strike })
        assertTrue(spans.any { it.text == "f" && it.url == "http://x.y" })
        assertEquals("a b c d e f end", spans.joinToString("") { it.text })
    }

    @Test fun plainTextIsOneSpan() {
        assertEquals(listOf(InlineSpan("plain text")), MarkdownParser.inline("plain text"))
    }
}
