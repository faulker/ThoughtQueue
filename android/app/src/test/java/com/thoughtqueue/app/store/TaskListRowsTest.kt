package com.thoughtqueue.app.store

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.Random

/** Ports of the desktop ChecklistRowsTests, including the round-trip fuzz. */
class TaskListRowsTest {
    private fun assertRoundTrips(s: String) = assertEquals(s, TaskRows.body(TaskRows.rows(s)))

    @Test fun roundTripAcrossRepresentativeBodies() {
        for (s in listOf(
            "", "\n", "- [ ] a", "- [ ] a\n", "# H\n\n- [x] b\r\n- [ ] c\r\n", "prose\n- [ ]\n\t* [X]   t  \n",
            "   \n- [ ]   \n", "#nospace\n####### seven\n", "- [ ] a\r", "\r\n\r\n",
        )) assertRoundTrips(s)
    }

    @Test fun roundTripFuzz() {
        val alphabet = listOf(
            "- [ ] item", "- [x] done", "* [X] star", "+ [ ] plus", "  - [ ] indented",
            "\t- [ ] tabbed", "- [ ]", "- [ ]   padded  ", "# Heading", "### Deep",
            "#tag", "", "   ", "\t", "prose line", "- bullet", "1. numbered",
            "| a | b |", "---", "> quote", "```", "- [y] bad marker", "- [x]nospace",
            "- [ ] café ☃", "- [ ] \r inner", " - [ ] odd",
        )
        val rng = Random(42)
        repeat(2000) {
            val count = rng.nextInt(13)
            val lines = (0 until count).map {
                var line = alphabet[rng.nextInt(alphabet.size)]
                if (rng.nextBoolean()) line += "\r"
                line
            }
            assertRoundTrips(lines.joinToString("\n"))
        }
    }

    @Test fun taskRowKeepsEveryPieceVerbatim() {
        val row = TaskRows.row("\t  * [X]   spaced   text  ")
        val task = (row.kind as RowKind.Task).task
        assertEquals("\t  ", task.indent)
        assertEquals('*', task.bullet)
        assertEquals(" ", task.spacing)
        assertEquals('X', task.marker)
        assertEquals(" ", task.gap)
        assertEquals("  spaced   text  ", task.text)
        assertTrue(task.checked)
    }

    @Test fun headingBlankAndOtherRows() {
        assertTrue(TaskRows.row("## Title").kind is RowKind.Heading)
        assertTrue(TaskRows.row("   ").kind is RowKind.Blank)
        assertTrue(TaskRows.row("prose").kind is RowKind.Other)
    }

    @Test fun carriageReturnIsPreserved() {
        val row = TaskRows.row("- [ ] a\r")
        assertTrue(row.carriageReturn)
        assertEquals("- [ ] a\r", TaskRows.line(row))
    }

    @Test fun newTaskRowInheritsBulletIndentAndLineEnding() {
        val template = TaskRows.row("  * [x] a\r")
        val fresh = TaskRows.newTaskRow(template)
        assertEquals("  * [ ] \r", TaskRows.line(fresh))
    }

    @Test fun settingCheckedWritesLowercaseAndChangesNothingElse() {
        val rows = TaskRows.rows("- [ ] a\n* [X] b")
        assertEquals("- [x] a\n* [X] b", TaskRows.body(TaskRows.settingChecked(true, 0, rows)))
        assertEquals("- [ ] a\n* [ ] b", TaskRows.body(TaskRows.settingChecked(false, 1, rows)))
    }

    @Test fun splitThenMergeIsIdentity() {
        val rows = TaskRows.rows("- [ ] hello world")
        val split = TaskRows.splittingTask(0, 5, rows)
        assertEquals("- [ ] hello\n- [ ]  world", TaskRows.body(split.rows))
        assertEquals(1, split.focusRow)
        val merged = TaskRows.mergingRowIntoPrevious(1, split.rows)
        assertEquals("- [ ] hello world", TaskRows.body(merged.rows))
        assertEquals(5, merged.focusOffset)
    }

    @Test fun mergingAfterAHeadingIsANoOp() {
        val rows = TaskRows.rows("# H\n- [ ] a")
        assertEquals(rows, TaskRows.mergingRowIntoPrevious(1, rows).rows)
    }

    @Test fun deletingTheLastTaskSubstitutesAFreshEmptyOne() {
        val rows = TaskRows.rows("- [ ] only")
        val edit = TaskRows.deletingRow(0, rows)
        assertEquals("- [ ] ", TaskRows.body(edit.rows))
    }

    @Test fun deletingFocusesTheEndOfThePreviousRow() {
        val rows = TaskRows.rows("- [ ] one\n- [ ] two")
        val edit = TaskRows.deletingRow(1, rows)
        assertEquals("- [ ] one", TaskRows.body(edit.rows))
        assertEquals(0, edit.focusRow)
        assertEquals(3, edit.focusOffset)
    }

    @Test fun insertingTaskInheritsAndFocusesTheNewRow() {
        val rows = TaskRows.rows("* [ ] a")
        val edit = TaskRows.insertingTask(0, rows)
        assertEquals("* [ ] a\n* [ ] ", TaskRows.body(edit.rows))
        assertEquals(1, edit.focusRow)
    }

    @Test fun appendAnchorSkipsTrailingBlanks() {
        val rows = TaskRows.rows("- [ ] a\n\n")
        assertEquals(0, TaskRows.appendAnchor(rows))
    }

    @Test fun settingTextGivesABareItemItsSeparator() {
        val rows = TaskRows.rows("- [ ]")
        assertEquals("- [ ] hi", TaskRows.body(TaskRows.settingText("hi", 0, rows)))
    }
}
