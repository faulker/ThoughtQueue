package com.thoughtqueue.app.store

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** Ports of the desktop fuzzy-search tests. */
class FuzzySearchTest {
    private fun note(title: String) = Note(File("/x/$title.md"), title, null, 0, 0)

    @Test fun scoreMatchesSubsequence() {
        assertNotNull(FuzzySearch.score("gcr", "grocery-checklist"))
        assertNull(FuzzySearch.score("xyz", "grocery"))
        assertNull(FuzzySearch.score("ba", "ab"))
        assertEquals(0, FuzzySearch.score("", "anything"))
        assertNull(FuzzySearch.score("a", ""))
    }

    @Test fun emptyQueryReturnsAllInOrder() {
        val notes = listOf(note("b"), note("a"))
        assertEquals(notes, FuzzySearch.rank(notes, "   "))
    }

    @Test fun ranksContiguousAndPrefixHigher() {
        val notes = listOf(note("axbxc"), note("abc"), note("xabc"))
        val ranked = FuzzySearch.rank(notes, "abc").map { it.title }
        assertEquals("abc", ranked.first())
// A first-character match also earns the contiguous bonus, as on the desktop.
        assertEquals(listOf("abc", "axbxc", "xabc"), ranked)
    }

    @Test fun nonMatchesAreDropped() {
        assertTrue(FuzzySearch.rank(listOf(note("alpha")), "zzz").isEmpty())
    }
}
