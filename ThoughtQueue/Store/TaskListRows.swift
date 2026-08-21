import Foundation

/// Decomposes a markdown body into editable rows and reassembles it byte for byte.
///
/// The checklist editor needs to rewrite individual lines while leaving the rest of the file
/// untouched, so every row keeps enough verbatim detail to reproduce its source line exactly:
/// indentation, bullet character, the whitespace around the marker, the separator after `]`,
/// trailing content, and whether the line ended CRLF.
///
/// The round-trip is guaranteed rather than hoped for: `row(from:)` re-serializes its own
/// candidate and compares it against the original line, falling back to `.other` (verbatim) on
/// any mismatch. So `body(from: rows(from: s)) == s` holds for every input, not only the cases
/// anticipated here, and stays true if the parsing rules change later.
extension TaskList {

    /// One source line, decomposed far enough to edit and reassemble.
    struct Row: Equatable {
        enum Kind: Equatable {
            case task(Task)
            case heading(Heading)
            /// A blank line, kept verbatim (may hold whitespace).
            case blank(String)
            /// Anything the checklist editor does not model, kept verbatim.
            case other(String)
        }

        var kind: Kind
        /// True when the source line ended "\r\n", so CRLF files stay CRLF.
        var carriageReturn: Bool

        init(kind: Kind, carriageReturn: Bool = false) {
            self.kind = kind
            self.carriageReturn = carriageReturn
        }

        var isTask: Bool { if case .task = kind { return true }; return false }
        var isBlank: Bool { if case .blank = kind { return true }; return false }

        /// The editable text of the row, empty for a blank line.
        var text: String {
            switch kind {
            case .task(let task): return task.text
            case .heading(let heading): return heading.text
            case .blank: return ""
            case .other(let raw): return raw
            }
        }

        var checked: Bool {
            if case .task(let task) = kind { return task.checked }
            return false
        }
    }

    /// A task line's pieces. `marker` and `gap` are kept exactly as written so an untouched
    /// line reproduces itself; edits normalize only what they have to.
    struct Task: Equatable {
        var indent: String
        var bullet: Character
        /// Whitespace between the bullet and `[`.
        var spacing: String
        /// The character between the brackets, verbatim (" ", "x", or "X").
        var marker: Character
        /// The single space or tab after `]`, or "" for a bare `- [ ]`.
        var gap: String
        /// Everything after the gap, verbatim (may hold trailing whitespace).
        var text: String

        var checked: Bool { marker == "x" || marker == "X" }

        /// Writes lowercase `x`, matching `TaskList.toggled`.
        mutating func setChecked(_ on: Bool) {
            marker = on ? "x" : " "
            // An item that gained text needs a separator; a bare "- [ ]" has none yet.
            if gap.isEmpty && !text.isEmpty { gap = " " }
        }
    }

    /// An ATX heading line, shown as a section label in the checklist.
    struct Heading: Equatable {
        var indent: String
        /// Number of leading `#`, 1...6.
        var level: Int
        /// Whitespace between the hashes and the text.
        var spacing: String
        var text: String
    }

    // MARK: - Line parsing

    private static let headingRegex = try? NSRegularExpression(pattern: #"^([ \t]*)(#{1,6})([ \t]+)(.*)$"#)

    /// Decompose one line (without its newline).
    static func row(from line: String) -> Row {
        var content = line
        var carriageReturn = false
        if content.hasSuffix("\r") {
            content.removeLast()
            carriageReturn = true
        }

        let candidate = classify(content, carriageReturn: carriageReturn)
        // The round-trip guard: anything that cannot reproduce itself is kept verbatim.
        guard self.line(from: candidate) == line else {
            return Row(kind: .other(content), carriageReturn: carriageReturn)
        }
        return candidate
    }

    private static func classify(_ content: String, carriageReturn: Bool) -> Row {
        if let match = firstMatch(in: content) {
            let ns = content as NSString
            let bullet = ns.substring(with: match.range(at: 2)).first ?? "-"
            let marker = ns.substring(with: match.range(at: 4)).first ?? " "
            let textRange = match.range(at: 5)
            let text = textRange.location == NSNotFound ? "" : ns.substring(with: textRange)
            // Group 5 participates only when a separator was present; reconstruct it from the
            // span between `]` and the text rather than assuming a single space.
            let gap: String
            if textRange.location == NSNotFound {
                // No text: whatever trails the bracket is padding, kept as the gap.
                let afterBracket = match.range(at: 4).location + 2
                gap = ns.substring(from: min(afterBracket, ns.length))
            } else {
                let afterBracket = match.range(at: 4).location + 2
                gap = ns.substring(with: NSRange(location: afterBracket,
                                                 length: max(0, textRange.location - afterBracket)))
            }
            let task = Task(indent: ns.substring(with: match.range(at: 1)),
                            bullet: bullet,
                            spacing: ns.substring(with: match.range(at: 3)),
                            marker: marker,
                            gap: gap,
                            text: text)
            return Row(kind: .task(task), carriageReturn: carriageReturn)
        }

        if let headingRegex,
           let match = headingRegex.firstMatch(in: content,
                                               range: NSRange(location: 0, length: (content as NSString).length)) {
            let ns = content as NSString
            let heading = Heading(indent: ns.substring(with: match.range(at: 1)),
                                  level: ns.substring(with: match.range(at: 2)).count,
                                  spacing: ns.substring(with: match.range(at: 3)),
                                  text: ns.substring(with: match.range(at: 4)))
            return Row(kind: .heading(heading), carriageReturn: carriageReturn)
        }

        if content.trimmingCharacters(in: .whitespaces).isEmpty {
            return Row(kind: .blank(content), carriageReturn: carriageReturn)
        }
        return Row(kind: .other(content), carriageReturn: carriageReturn)
    }

    /// Reassemble one row into its source line (without a newline).
    static func line(from row: Row) -> String {
        var content: String
        switch row.kind {
        case .task(let task):
            content = task.indent + String(task.bullet) + task.spacing
                + "[" + String(task.marker) + "]" + task.gap + task.text
        case .heading(let heading):
            content = heading.indent + String(repeating: "#", count: heading.level)
                + heading.spacing + heading.text
        case .blank(let raw):
            content = raw
        case .other(let raw):
            content = raw
        }
        return row.carriageReturn ? content + "\r" : content
    }

    // MARK: - Body parsing

    /// Split a body into rows. Uses the same "\n" split as `toggle(body:lineIndex:)` and
    /// `MarkdownRenderer.render`, so a row index is also a `.tqTaskSourceLine` index.
    static func rows(from body: String) -> [Row] {
        body.components(separatedBy: "\n").map(row(from:))
    }

    /// Reassemble rows into a body. A trailing newline round-trips as a final blank row.
    static func body(from rows: [Row]) -> String {
        rows.map(line(from:)).joined(separator: "\n")
    }
}

/// Structural edits over rows, expressed purely so the checklist editor's keyboard behavior is
/// testable without views. Each returns the new rows plus where the caret belongs afterwards.
extension TaskList {

    struct Edit: Equatable {
        var rows: [Row]
        var focusRow: Int
        var focusOffset: Int
    }

    /// A fresh unchecked, empty task row that inherits indentation, bullet, spacing and line
    /// ending from `template`, so adding an item to a `*`-bulleted CRLF list stays consistent.
    static func newTaskRow(like template: Row?) -> Row {
        if let template, case .task(let task) = template.kind {
            let fresh = Task(indent: task.indent, bullet: task.bullet, spacing: task.spacing,
                             marker: " ", gap: " ", text: "")
            return Row(kind: .task(fresh), carriageReturn: template.carriageReturn)
        }
        let fresh = Task(indent: "", bullet: "-", spacing: " ", marker: " ", gap: " ", text: "")
        return Row(kind: .task(fresh), carriageReturn: template?.carriageReturn ?? false)
    }

    /// Insert an empty item below `index`.
    static func insertingTask(after index: Int, in rows: [Row]) -> Edit {
        var updated = rows
        let template = rows.indices.contains(index) ? rows[index] : rows.last
        let insertAt = min(index + 1, updated.count)
        updated.insert(newTaskRow(like: template), at: insertAt)
        return Edit(rows: updated, focusRow: insertAt, focusOffset: 0)
    }

    /// Split the item at `index` at `offset`: the row keeps the prefix, a new row below takes
    /// the suffix. The exact inverse of `mergingRowIntoPrevious`.
    static func splittingTask(at index: Int, offset: Int, in rows: [Row]) -> Edit {
        guard rows.indices.contains(index), case .task(var task) = rows[index].kind else {
            return Edit(rows: rows, focusRow: index, focusOffset: offset)
        }
        var updated = rows
        let clamped = min(max(offset, 0), task.text.count)
        let splitIndex = task.text.index(task.text.startIndex, offsetBy: clamped)
        let suffix = String(task.text[splitIndex...])
        task.text = String(task.text[..<splitIndex])
        updated[index].kind = .task(task)

        var trailing = newTaskRow(like: rows[index])
        if case .task(var next) = trailing.kind {
            next.text = suffix
            trailing.kind = .task(next)
        }
        updated.insert(trailing, at: index + 1)
        return Edit(rows: updated, focusRow: index + 1, focusOffset: 0)
    }

    /// Delete a row, focusing the end of the previous editable row. Never leaves the body
    /// without a task row: deleting the last one substitutes a fresh empty item, so a list
    /// cannot stop being a list mid-typing and pull the editor out from under the user.
    static func deletingRow(at index: Int, in rows: [Row]) -> Edit {
        guard rows.indices.contains(index) else {
            return Edit(rows: rows, focusRow: index, focusOffset: 0)
        }
        var updated = rows
        updated.remove(at: index)

        if !updated.contains(where: { $0.isTask }) {
            let fresh = newTaskRow(like: rows[index])
            let insertAt = min(index, updated.count)
            updated.insert(fresh, at: insertAt)
            return Edit(rows: updated, focusRow: insertAt, focusOffset: 0)
        }

        let previous = previousEditableIndex(before: index, in: updated)
        let focus = previous ?? nextEditableIndex(atOrAfter: index, in: updated) ?? 0
        return Edit(rows: updated, focusRow: focus, focusOffset: updated[focus].text.count)
    }

    /// Append this row's text to the previous item and delete it. A no-op when there is no
    /// previous row or it is not a task, so item text never folds into a section label.
    static func mergingRowIntoPrevious(at index: Int, in rows: [Row]) -> Edit {
        guard rows.indices.contains(index), index > 0,
              case .task(let current) = rows[index].kind,
              case .task(var previous) = rows[index - 1].kind else {
            return Edit(rows: rows, focusRow: index, focusOffset: 0)
        }
        var updated = rows
        let join = previous.text.count
        previous.text += current.text
        updated[index - 1].kind = .task(previous)
        updated.remove(at: index)
        return Edit(rows: updated, focusRow: index - 1, focusOffset: join)
    }

    static func settingText(_ text: String, at index: Int, in rows: [Row]) -> [Row] {
        guard rows.indices.contains(index) else { return rows }
        var updated = rows
        switch updated[index].kind {
        case .task(var task):
            task.text = text
            // A bare "- [ ]" needs a separator once it holds text.
            if task.gap.isEmpty && !text.isEmpty { task.gap = " " }
            updated[index].kind = .task(task)
        case .heading(var heading):
            heading.text = text
            updated[index].kind = .heading(heading)
        case .blank:
            break
        case .other:
            updated[index].kind = .other(text)
        }
        return updated
    }

    static func settingChecked(_ on: Bool, at index: Int, in rows: [Row]) -> [Row] {
        guard rows.indices.contains(index), case .task(var task) = rows[index].kind else {
            return rows
        }
        var updated = rows
        task.setChecked(on)
        updated[index].kind = .task(task)
        return updated
    }

    /// Where "+ Add item" appends: after the last task or heading, so trailing blank lines and
    /// the file's final newline stay at the end instead of being pushed down per item.
    static func appendAnchor(in rows: [Row]) -> Int {
        for index in rows.indices.reversed() where !rows[index].isBlank {
            return index
        }
        return rows.count - 1
    }

    /// Rows the user can put a caret in. Blank rows are invisible structure.
    static func isEditable(_ row: Row) -> Bool { !row.isBlank }

    static func previousEditableIndex(before index: Int, in rows: [Row]) -> Int? {
        stride(from: min(index, rows.count) - 1, through: 0, by: -1).first { rows[$0].isTask || !rows[$0].isBlank }
    }

    static func nextEditableIndex(atOrAfter index: Int, in rows: [Row]) -> Int? {
        rows.indices.filter { $0 >= index }.first { !rows[$0].isBlank }
    }
}
