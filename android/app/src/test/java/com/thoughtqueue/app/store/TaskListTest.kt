package com.thoughtqueue.app.store

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** Ports of the desktop TaskListTests: parsing, surgical toggling, Return handling, classification. */
class TaskListTest {
    @Test fun toggleUncheckedToChecked() = assertEquals("- [x] milk", TaskList.toggled("- [ ] milk"))

    @Test fun toggleCheckedToUnchecked() = assertEquals("- [ ] milk", TaskList.toggled("- [x] milk"))

    @Test fun uppercaseMarkerIsRecognizedAndWrittenBackLowercase() {
        assertEquals("- [ ] a", TaskList.toggled("- [X] a"))
        assertEquals(true, TaskList.parse("- [X] a")?.checked)
    }

    @Test fun bulletIndentSpacingAndTrailingContentSurvive() {
        assertEquals("  * [x]   spaced  text  ", TaskList.toggled("  * [ ]   spaced  text  "))
        assertEquals("\t+ [x] t", TaskList.toggled("\t+ [ ] t"))
    }

    @Test fun emptyItemParsesWithOrWithoutTrailingSpace() {
        assertEquals("", TaskList.parse("- [ ]")?.text)
        assertEquals("", TaskList.parse("- [ ] ")?.text)
    }

    @Test fun nonTaskLinesReturnNull() {
        for (s in listOf("", "prose", "- bullet", "- [y] x", "- [x]nospace", "[ ] x", "1. [ ] x")) {
            assertNull(s, TaskList.parse(s))
            assertNull(s, TaskList.toggled(s))
        }
    }

    @Test fun togglingOneLineLeavesEveryOtherLineByteIdentical() {
        val body = "# Title\r\n- [ ] a\r\n  - [x] b\r\n\r\nprose\r\n- [ ] c\r\n"
        val out = TaskList.toggle(body, 1)!!
        val before = body.split("\n")
        val after = out.split("\n")
        assertEquals(before.size, after.size)
        for (i in before.indices) {
            if (i == 1) assertEquals("- [x] a\r", after[i]) else assertEquals(before[i], after[i])
        }
    }

    @Test fun outOfRangeAndNonTaskIndicesReturnNull() {
        assertNull(TaskList.toggle("- [ ] a", 5))
        assertNull(TaskList.toggle("prose\n- [ ] a", 0))
    }

    @Test fun doubleToggleRoundTrips() {
        val body = "- [ ] a\n* [x] b\n"
        assertEquals(body, TaskList.toggle(TaskList.toggle(body, 0)!!, 0))
    }

    @Test fun isCheckedReadsTheMarker() {
        assertEquals(true, TaskList.isChecked("- [x] a", 0))
        assertEquals(false, TaskList.isChecked("- [ ] a", 0))
        assertNull(TaskList.isChecked("x", 0))
    }

    @Test fun toggleOrPromoteTurnsProseIntoATaskAndReusesBullets() {
        assertEquals("- [ ] hello", TaskList.toggleOrPromote("hello", 0))
        assertEquals("  - [ ] hello", TaskList.toggleOrPromote("  hello", 0))
        assertEquals("* [ ] hello", TaskList.toggleOrPromote("* hello", 0))
        assertEquals("- [ ] ", TaskList.toggleOrPromote("", 0))
        assertEquals("- [x] a", TaskList.toggleOrPromote("- [ ] a", 0))
    }

    @Test fun returnContinuesAListUncheckedKeepingBulletAndIndent() {
        assertEquals(TaskList.ReturnAction.ContinueList("- [ ] "), TaskList.returnAction("- [x] milk"))
        assertEquals(TaskList.ReturnAction.ContinueList("  * [ ] "), TaskList.returnAction("  * [ ] milk"))
    }

    @Test fun returnOnEmptyItemClearsTheMarker() {
        assertEquals(TaskList.ReturnAction.ClearMarker, TaskList.returnAction("- [ ] "))
        assertEquals(TaskList.ReturnAction.ClearMarker, TaskList.returnAction("- [ ]"))
        assertEquals(TaskList.ReturnAction.ClearMarker, TaskList.returnAction("2. "))
        assertEquals(TaskList.ReturnAction.ClearMarker, TaskList.returnAction("- "))
    }

    @Test fun returnContinuesOrderedAndBulletLists() {
        assertEquals(TaskList.ReturnAction.ContinueList("2. "), TaskList.returnAction("1. one"))
        assertEquals(TaskList.ReturnAction.ContinueList("  10) "), TaskList.returnAction("  9) nine"))
        assertEquals(TaskList.ReturnAction.ContinueList("* "), TaskList.returnAction("* item"))
    }

    @Test fun returnPassesThroughOnProse() {
        assertEquals(TaskList.ReturnAction.Pass, TaskList.returnAction("just text"))
        assertEquals(TaskList.ReturnAction.Pass, TaskList.returnAction(""))
    }

    @Test fun applyReturnContinuesAtEndOfLine() {
        val edit = TaskList.applyReturn("- [ ] a\n- [ ] b", 15)!!
        assertEquals("- [ ] a\n- [ ] b\n- [ ] ", edit.text)
        assertEquals(edit.text.length, edit.cursor)
    }

    @Test fun applyReturnMidItemIsAPlainNewline() {
        assertNull(TaskList.applyReturn("- [ ] abc", 7))
    }

    @Test fun applyReturnOnEmptyItemWipesItInPlace() {
        val edit = TaskList.applyReturn("1. one\n2. ", 10)!!
        assertEquals("1. one\n", edit.text)
        assertEquals(7, edit.cursor)
    }

    @Test fun applyReturnIgnoresProse() {
        assertNull(TaskList.applyReturn("hello", 5))
    }

    @Test fun isChecklistAcceptsPureAndHeadedLists() {
        assertTrue(TaskList.isChecklist("- [ ] a\n- [x] b\n"))
        assertTrue(TaskList.isChecklist("# Groceries\n\n- [ ] milk"))
    }

    @Test fun isChecklistRejectsProseAndMixedDocuments() {
        assertFalse(TaskList.isChecklist(""))
        assertFalse(TaskList.isChecklist("# Only heading"))
        assertFalse(TaskList.isChecklist("some prose\n- [ ] a"))
        assertFalse(TaskList.isChecklist("- [ ] a\n- plain bullet"))
        assertNotNull(TaskList.parse("- [ ] a"))
    }
}
