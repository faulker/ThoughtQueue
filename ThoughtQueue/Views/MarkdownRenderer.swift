import Cocoa

/// Renders block-level markdown to an NSAttributedString for read-only display.
/// Apple's `NSAttributedString(markdown:)` flattens block structure (headings/lists become
/// plain text). This renderer handles the blocks ThoughtQueue actually uses: headings,
/// bullet/numbered lists, and `- [ ]` / `- [x]` task checkboxes (the meeting-todos case).
/// Inline emphasis within a line is delegated to the system markdown parser.
enum MarkdownRenderer {

    /// Render `markdown` into an attributed string with block-level structure, using `baseFont`
    /// as the body font. Headings are scaled relative to the base size and bolded.
    static func render(_ markdown: String, baseFont: NSFont = .systemFont(ofSize: 13)) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let lines = markdown.components(separatedBy: "\n")

        var index = 0
        while index < lines.count {
            // GFM tables span multiple lines (header, delimiter, data rows). Detect and render
            // the whole block as a real NSTextTable before falling back to line-at-a-time.
            if let table = parseTableBlock(lines, at: index) {
                // Cells terminate their own paragraphs, so the table already ends with a newline;
                // no extra separator is needed before the next block.
                result.append(renderTable(table, baseFont: baseFont))
                index += table.consumed
                continue
            }

            let attributed = renderLine(lines[index], baseFont: baseFont)
            result.append(attributed)
            if index < lines.count - 1 {
                result.append(NSAttributedString(string: "\n"))
            }
            index += 1
        }
        return result
    }

    /// Render a single line as a block element.
    private static func renderLine(_ line: String, baseFont: NSFont) -> NSAttributedString {
        let trimmed = line.trimmingCharacters(in: .whitespaces)

        // Task checkboxes: - [ ] / - [x]  (rendered with a visible box glyph).
        if let task = parseTask(trimmed) {
            let box = task.checked ? "\u{2611} " : "\u{2610} "   // ☑ / ☐
            let body = inline(task.text, baseFont: baseFont)
            let combined = NSMutableAttributedString(string: box, attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.labelColor,
            ])
            if task.checked {
                body.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue,
                                  range: NSRange(location: 0, length: body.length))
                body.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor,
                                  range: NSRange(location: 0, length: body.length))
            }
            combined.append(body)
            return prefixed("  ", combined, baseFont: baseFont)
        }

        // Headings: #, ##, ### ...
        if let heading = parseHeading(trimmed) {
            let multiplier: CGFloat
            switch heading.level {
            case 1: multiplier = 1.7
            case 2: multiplier = 1.4
            case 3: multiplier = 1.22
            default: multiplier = 1.08
            }
            let headingFont = bold(sized(baseFont, baseFont.pointSize * multiplier))
            let body = inline(heading.text, baseFont: baseFont)
            body.addAttributes([.font: headingFont],
                               range: NSRange(location: 0, length: body.length))
            return body
        }

        // Bullet list: -, *, +
        if let bullet = parseBullet(trimmed) {
            let body = inline(bullet, baseFont: baseFont)
            return prefixed("  \u{2022} ", body, baseFont: baseFont)
        }

        // Numbered list: 1. 2) etc.
        if let numbered = parseNumbered(trimmed) {
            let body = inline(numbered.text, baseFont: baseFont)
            return prefixed("  \(numbered.number). ", body, baseFont: baseFont)
        }

        // Plain paragraph (inline emphasis preserved).
        return inline(line, baseFont: baseFont)
    }

    // MARK: - Font helpers

    private static func sized(_ font: NSFont, _ size: CGFloat) -> NSFont {
        NSFont(descriptor: font.fontDescriptor, size: size) ?? font
    }

    private static func bold(_ font: NSFont) -> NSFont {
        NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
    }

    // MARK: - Inline

    /// Parse inline markdown (bold/italic/code) within a single line using the system parser,
    /// falling back to plain text. Reapplies `baseFont` to each run while keeping the parser's
    /// bold/italic traits, so the configured editor font carries through.
    private static func inline(_ text: String, baseFont: NSFont) -> NSMutableAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ]
        guard !text.isEmpty else {
            return NSMutableAttributedString(string: "", attributes: base)
        }
        if let parsed = try? NSAttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            let m = NSMutableAttributedString(attributedString: parsed)
            let full = NSRange(location: 0, length: m.length)
            // Map each run onto baseFont, preserving bold/italic traits from the parser.
            m.enumerateAttribute(.font, in: full) { value, range, _ in
                var font = baseFont
                if let existing = value as? NSFont {
                    let traits = existing.fontDescriptor.symbolicTraits
                    if traits.contains(.bold) { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
                    if traits.contains(.italic) { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
                }
                m.addAttribute(.font, value: font, range: range)
            }
            m.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)
            return m
        }
        return NSMutableAttributedString(string: text, attributes: base)
    }

    private static func prefixed(_ prefix: String, _ body: NSAttributedString, baseFont: NSFont) -> NSAttributedString {
        let m = NSMutableAttributedString(string: prefix, attributes: [
            .font: baseFont,
            .foregroundColor: NSColor.labelColor,
        ])
        m.append(body)
        return m
    }

    // MARK: - Tables (internal for testing)

    enum CellAlignment { case leading, center, trailing }

    struct TableBlock {
        let header: [String]
        let alignments: [CellAlignment]
        let rows: [[String]]
        /// Number of source lines this table consumed (header + delimiter + data rows).
        let consumed: Int
        /// Widest row, so short rows get padded with empty trailing cells.
        var columnCount: Int { max(header.count, rows.map(\.count).max() ?? 0) }
    }

    /// Detect a GitHub-flavored markdown table starting at `index`: a header row, a delimiter
    /// row (`| --- | :--: |`), then zero or more data rows. Returns nil if `index` isn't a table.
    static func parseTableBlock(_ lines: [String], at index: Int) -> TableBlock? {
        guard index + 1 < lines.count else { return nil }
        guard isTableRow(lines[index]) else { return nil }
        guard let alignments = parseDelimiterRow(lines[index + 1]) else { return nil }

        let header = splitRow(lines[index])
        guard !header.isEmpty else { return nil }

        var rows: [[String]] = []
        var i = index + 2
        while i < lines.count, isTableRow(lines[i]) {
            rows.append(splitRow(lines[i]))
            i += 1
        }
        return TableBlock(header: header, alignments: alignments, rows: rows, consumed: i - index)
    }

    /// A candidate table row: non-empty once trimmed and containing at least one pipe.
    private static func isTableRow(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return !trimmed.isEmpty && trimmed.contains("|")
    }

    /// Split a `| a | b |` row into trimmed cells, dropping the optional outer border pipes.
    static func splitRow(_ line: String) -> [String] {
        var s = line.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
    }

    /// Parse a delimiter row into per-column alignments, or nil if any cell isn't `:?-+:?`.
    static func parseDelimiterRow(_ line: String) -> [CellAlignment]? {
        guard isTableRow(line) else { return nil }
        let cells = splitRow(line)
        guard !cells.isEmpty else { return nil }

        var alignments: [CellAlignment] = []
        for cell in cells {
            guard firstMatch(cell, #"^:?-+:?$"#) != nil else { return nil }
            let left = cell.hasPrefix(":")
            let right = cell.hasSuffix(":")
            if left && right { alignments.append(.center) }
            else if right { alignments.append(.trailing) }
            else { alignments.append(.leading) }
        }
        return alignments
    }

    /// Build a real `NSTextTable` (bordered cells, bold header row) from a parsed table block.
    private static func renderTable(_ block: TableBlock, baseFont: NSFont) -> NSAttributedString {
        let columns = block.columnCount
        let table = NSTextTable()
        table.numberOfColumns = columns
        table.layoutAlgorithm = .automaticLayoutAlgorithm
        table.setContentWidth(100, type: .percentageValueType)

        let headerFont = bold(baseFont)
        var sourceRows: [(cells: [String], isHeader: Bool)] = [(block.header, true)]
        sourceRows.append(contentsOf: block.rows.map { ($0, false) })

        let result = NSMutableAttributedString()
        for (rowIndex, row) in sourceRows.enumerated() {
            for column in 0..<columns {
                let text = column < row.cells.count ? row.cells[column] : ""

                let cellBlock = NSTextTableBlock(table: table, startingRow: rowIndex, rowSpan: 1,
                                                 startingColumn: column, columnSpan: 1)
                cellBlock.setBorderColor(.separatorColor)
                cellBlock.setWidth(1, type: .absoluteValueType, for: .border)
                cellBlock.setWidth(6, type: .absoluteValueType, for: .padding)
                if row.isHeader {
                    cellBlock.backgroundColor = .underPageBackgroundColor
                }

                let paragraph = NSMutableParagraphStyle()
                paragraph.textBlocks = [cellBlock]
                let alignment = column < block.alignments.count ? block.alignments[column] : .leading
                switch alignment {
                case .leading: paragraph.alignment = .left
                case .center: paragraph.alignment = .center
                case .trailing: paragraph.alignment = .right
                }

                let cell = inline(text, baseFont: row.isHeader ? headerFont : baseFont)
                cell.append(NSAttributedString(string: "\n"))
                cell.addAttribute(.paragraphStyle, value: paragraph,
                                  range: NSRange(location: 0, length: cell.length))
                result.append(cell)
            }
        }
        return result
    }

    // MARK: - Block parsers (internal for testing)

    struct Task { let checked: Bool; let text: String }
    struct Heading { let level: Int; let text: String }
    struct Numbered { let number: Int; let text: String }

    static func parseTask(_ line: String) -> Task? {
        // - [ ] text   |   - [x] text   (also * and +)
        let pattern = #"^[-*+]\s+\[([ xX])\]\s+(.*)$"#
        guard let m = firstMatch(line, pattern) else { return nil }
        let mark = m[1].lowercased()
        return Task(checked: mark == "x", text: m[2])
    }

    static func parseHeading(_ line: String) -> Heading? {
        let pattern = #"^(#{1,6})\s+(.*)$"#
        guard let m = firstMatch(line, pattern) else { return nil }
        return Heading(level: m[1].count, text: m[2])
    }

    static func parseBullet(_ line: String) -> String? {
        // Must not be a task (caller checks tasks first, but be safe).
        if parseTask(line) != nil { return nil }
        let pattern = #"^[-*+]\s+(.*)$"#
        guard let m = firstMatch(line, pattern) else { return nil }
        return m[1]
    }

    static func parseNumbered(_ line: String) -> Numbered? {
        let pattern = #"^(\d+)[.)]\s+(.*)$"#
        guard let m = firstMatch(line, pattern), let n = Int(m[1]) else { return nil }
        return Numbered(number: n, text: m[2])
    }

    /// Return the full match plus capture groups as strings, or nil if no match.
    private static func firstMatch(_ string: String, _ pattern: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(string.startIndex..<string.endIndex, in: string)
        guard let match = regex.firstMatch(in: string, range: range) else { return nil }
        var groups: [String] = []
        for i in 0..<match.numberOfRanges {
            if let r = Range(match.range(at: i), in: string) {
                groups.append(String(string[r]))
            } else {
                groups.append("")
            }
        }
        return groups
    }
}
