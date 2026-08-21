import Foundation

/// Pure parsing and rewriting of GFM task lines (`- [ ] milk` / `- [x] eggs`).
///
/// A checklist is not a file format of its own: it is an ordinary markdown note whose lines
/// happen to be task lines. Everything here is a pure function over strings so it is directly
/// unit-testable, independent of the filesystem or UI (same shape as `FuzzySearch`).
///
/// The rewriters are deliberately surgical: only the single character between the brackets is
/// ever replaced, so indentation, bullet character, spacing, trailing content, and line endings
/// (including CRLF) survive byte for byte.
enum TaskList {

    /// The prefix a brand-new item is written with.
    static let newItemPrefix = "- [ ] "

    /// A parsed task line, with each piece kept verbatim so it can be reassembled losslessly.
    struct Line: Equatable {
        /// Leading whitespace, verbatim.
        let indent: String
        /// The list bullet: `-`, `*`, or `+`.
        let bullet: Character
        /// Whitespace between the bullet and `[`.
        let spacing: String
        let checked: Bool
        /// Content after the closing bracket, leading separator trimmed. May be empty.
        let text: String
    }

    /// What the Return key should do when pressed at the end of a line.
    enum ReturnAction: Equatable {
        /// Not a task line: let AppKit insert a plain newline.
        case pass
        /// Continue the list by inserting a newline plus this prefix.
        case continueList(prefix: String)
        /// The item is empty, so end the list by wiping the marker instead of continuing.
        case clearMarker
    }

    // MARK: - Parsing

    /// Matches a task line. Group 1 indent, 2 bullet, 3 spacing, 4 marker, 5 trailing content.
    /// The trailing group is optional so a bare `- [ ]` (no trailing space) still parses, which
    /// is the state that `clearMarker` and a half-typed item leave behind.
    private static let pattern = #"^([ \t]*)([-*+])([ \t]+)\[([ xX])\](?:[ \t](.*)|[ \t]*)$"#

    private static let regex = try? NSRegularExpression(pattern: pattern)

    /// Matches a plain bullet line, so promoting one reuses its bullet instead of doubling it.
    private static let bulletRegex = try? NSRegularExpression(pattern: #"^([-*+])([ \t]+)(.*)$"#)

    /// Parse a single line, or nil when it is not a task line.
    static func parse(_ line: String) -> Line? {
        guard let match = firstMatch(in: line) else { return nil }
        let ns = line as NSString
        let indent = ns.substring(with: match.range(at: 1))
        guard let bullet = ns.substring(with: match.range(at: 2)).first else { return nil }
        let spacing = ns.substring(with: match.range(at: 3))
        let marker = ns.substring(with: match.range(at: 4)).lowercased()
        let textRange = match.range(at: 5)
        let text = textRange.location == NSNotFound ? "" : ns.substring(with: textRange)
        return Line(indent: indent, bullet: bullet, spacing: spacing, checked: marker == "x", text: text)
    }

    static func isTaskLine(_ line: String) -> Bool {
        firstMatch(in: line) != nil
    }

    /// The regex is anchored with `$`, which in NSRegularExpression also matches before a
    /// trailing newline; callers always pass single lines, so the whole-string range is right.
    static func firstMatch(in line: String) -> NSTextCheckingResult? {
        guard let regex else { return nil }
        let range = NSRange(location: 0, length: (line as NSString).length)
        return regex.firstMatch(in: line, options: [.anchored], range: range)
    }

    // MARK: - Rewriting

    /// Flip one line's marker. Returns nil when `line` is not a task line.
    /// Uppercase `[X]` is recognized on the way in; we always write lowercase `x`.
    static func toggled(_ line: String) -> String? {
        guard let match = firstMatch(in: line) else { return nil }
        let markerRange = match.range(at: 4)
        let ns = line as NSString
        let wasChecked = ns.substring(with: markerRange).lowercased() == "x"
        return ns.replacingCharacters(in: markerRange, with: wasChecked ? " " : "x")
    }

    /// Turn a non-task line into an unchecked task line, preserving indentation.
    /// A blank line becomes a bare new item.
    private static func promoted(_ line: String) -> String {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = String(line.dropFirst(indent.count))
        if rest.isEmpty { return indent + newItemPrefix }
        // An existing bullet is reused rather than doubled up.
        if let bulletRegex,
           let m = bulletRegex.firstMatch(in: rest, range: NSRange(location: 0, length: (rest as NSString).length)) {
            let ns = rest as NSString
            let bullet = ns.substring(with: m.range(at: 1))
            let spacing = ns.substring(with: m.range(at: 2))
            let text = ns.substring(with: m.range(at: 3))
            return indent + bullet + spacing + "[ ] " + text
        }
        return indent + newItemPrefix + rest
    }

    // MARK: - Body-level operations

    /// Flip the task on source line `index` of a whole markdown body, returning the new body.
    /// Returns nil when the index is out of range or that line is not a task line.
    ///
    /// Splits and joins on "\n" exactly as `MarkdownRenderer.render` does, so line indices here
    /// agree with the `.tqTaskSourceLine` attribute the renderer stamps, and every untouched
    /// line round-trips unchanged (a trailing newline becomes a final empty element and is
    /// restored by the join).
    static func toggle(body: String, lineIndex index: Int) -> String? {
        var lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return nil }
        guard let flipped = toggled(lines[index]) else { return nil }
        lines[index] = flipped
        return lines.joined(separator: "\n")
    }

    /// Checked state of the task on `index`, or nil when it is not a task line.
    static func isChecked(body: String, lineIndex index: Int) -> Bool? {
        let lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return nil }
        return parse(lines[index])?.checked
    }

    /// Toggle line `index` if it is already a task, otherwise turn it into one.
    /// Returns nil only when the index is out of range.
    static func toggleOrPromote(body: String, lineIndex index: Int) -> String? {
        var lines = body.components(separatedBy: "\n")
        guard lines.indices.contains(index) else { return nil }
        lines[index] = toggled(lines[index]) ?? promoted(lines[index])
        return lines.joined(separator: "\n")
    }

    // MARK: - Typing

    /// What Return should do when pressed at the end of `line`.
    /// A continued item always starts unchecked, and keeps the original bullet and indentation.
    static func returnAction(for line: String) -> ReturnAction {
        guard let task = parse(line) else { return .pass }
        if task.text.trimmingCharacters(in: .whitespaces).isEmpty { return .clearMarker }
        return .continueList(prefix: task.indent + String(task.bullet) + task.spacing + "[ ] ")
    }

    // MARK: - Classification

    /// True when `markdown` reads as a checklist rather than a prose document: it has at least
    /// one task line, and every line that is neither blank nor an ATX heading is a task line.
    ///
    /// Used to decide whether a note is presented as a checkbox list. Headings are allowed so a
    /// list can carry a title; anything else (prose, continuation lines, tables, rules) means
    /// this is a document that merely contains tasks, and should stay a markdown document.
    static func isChecklist(_ markdown: String) -> Bool {
        var sawTask = false
        for line in markdown.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isTaskLine(line) { sawTask = true; continue }
            if trimmed.hasPrefix("#") { continue }
            return false
        }
        return sawTask
    }
}
