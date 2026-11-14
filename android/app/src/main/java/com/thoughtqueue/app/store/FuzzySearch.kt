package com.thoughtqueue.app.store

/**
 * Lightweight subsequence fuzzy matcher for note titles. Pure functions, independent of the
 * filesystem or UI, so they are directly unit-testable.
 */
object FuzzySearch {
    /**
     * Match score for [query] against [candidate], or null when it does not match. Higher is
     * better. Case-insensitive subsequence with bonuses for contiguous runs and for
     * start-of-string and word-boundary hits.
     */
    fun score(query: String, candidate: String): Int? {
        val q = query.lowercase()
        val c = candidate.lowercase()
        if (q.isEmpty()) return 0
        if (c.isEmpty()) return null

        var qi = 0
        var score = 0
        var lastMatch = -1
        for (ci in c.indices) {
            if (qi >= q.length) break
            if (c[ci] == q[qi]) {
                score += 1
                if (lastMatch == ci - 1) score += 3
                if (ci == 0) score += 5
                else if (c[ci - 1] == ' ' || c[ci - 1] == '-' || c[ci - 1] == '_') score += 3
                lastMatch = ci
                qi += 1
            }
        }
        return if (qi == q.length) score else null
    }

    /** Rank notes by fuzzy match against their titles. A blank query returns the input order. */
    fun rank(notes: List<Note>, query: String): List<Note> {
        val trimmed = query.trim()
        if (trimmed.isEmpty()) return notes
        return notes
            .mapNotNull { note -> score(trimmed, note.title)?.let { note to it } }
            .sortedByDescending { it.second }
            .map { it.first }
    }
}
