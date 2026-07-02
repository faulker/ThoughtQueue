import Foundation

/// Lightweight subsequence fuzzy matcher for note titles. Pure functions so they are
/// directly unit-testable, independent of the filesystem or UI.
enum FuzzySearch {
    /// Returns a match score for `query` against `candidate`, or nil if it does not match.
    /// Higher is better. Matching is case-insensitive subsequence with bonuses for
    /// contiguous runs and start-of-string / word-boundary hits.
    static func score(query: String, candidate: String) -> Int? {
        let q = Array(query.lowercased())
        let c = Array(candidate.lowercased())
        if q.isEmpty { return 0 }
        if c.isEmpty { return nil }

        var qi = 0
        var score = 0
        var lastMatchIndex = -1

        for (ci, ch) in c.enumerated() {
            guard qi < q.count else { break }
            if ch == q[qi] {
                score += 1
                // Contiguous match bonus.
                if lastMatchIndex == ci - 1 { score += 3 }
                // Start-of-string or word-boundary bonus.
                if ci == 0 { score += 5 }
                else if c[ci - 1] == " " || c[ci - 1] == "-" || c[ci - 1] == "_" { score += 3 }
                lastMatchIndex = ci
                qi += 1
            }
        }

        // All query chars must be consumed in order.
        return qi == q.count ? score : nil
    }

    /// Rank notes by fuzzy match against their titles. Empty query returns the input order.
    static func rank(notes: [Note], query: String) -> [Note] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return notes }

        return notes
            .compactMap { note -> (Note, Int)? in
                guard let s = score(query: trimmed, candidate: note.title) else { return nil }
                return (note, s)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }
}
