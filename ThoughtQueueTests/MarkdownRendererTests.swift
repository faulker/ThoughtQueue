import XCTest
import AppKit
@testable import ThoughtQueue

final class MarkdownRendererTests: XCTestCase {

    // MARK: - Table detection

    func testParseTableBlockDetectsHeaderDelimiterAndRows() {
        let lines = [
            "| Name | Age |",
            "| --- | --- |",
            "| Ada | 36 |",
            "| Alan | 41 |",
        ]
        let table = MarkdownRenderer.parseTableBlock(lines, at: 0)
        XCTAssertNotNil(table)
        XCTAssertEqual(table?.header, ["Name", "Age"])
        XCTAssertEqual(table?.rows, [["Ada", "36"], ["Alan", "41"]])
        XCTAssertEqual(table?.consumed, 4)
        XCTAssertEqual(table?.columnCount, 2)
    }

    func testParseTableBlockWithoutOuterPipes() {
        let lines = [
            "Name | Age",
            "--- | ---",
            "Ada | 36",
        ]
        let table = MarkdownRenderer.parseTableBlock(lines, at: 0)
        XCTAssertEqual(table?.header, ["Name", "Age"])
        XCTAssertEqual(table?.rows, [["Ada", "36"]])
    }

    func testParseTableBlockRequiresDelimiterRow() {
        // Two pipe rows but no `---` delimiter: not a table.
        let lines = [
            "| Name | Age |",
            "| Ada | 36 |",
        ]
        XCTAssertNil(MarkdownRenderer.parseTableBlock(lines, at: 0))
    }

    func testParseTableBlockRejectsPlainParagraphWithPipe() {
        let lines = [
            "use a | b to pipe output",
            "more prose here",
        ]
        XCTAssertNil(MarkdownRenderer.parseTableBlock(lines, at: 0))
    }

    func testParseTableBlockStopsAtFirstNonRow() {
        let lines = [
            "| A | B |",
            "| --- | --- |",
            "| 1 | 2 |",
            "",
            "| 3 | 4 |",
        ]
        let table = MarkdownRenderer.parseTableBlock(lines, at: 0)
        XCTAssertEqual(table?.consumed, 3)        // blank line ends the table
        XCTAssertEqual(table?.rows, [["1", "2"]])
    }

    // MARK: - Alignment

    func testParseDelimiterRowAlignments() {
        let aligns = MarkdownRenderer.parseDelimiterRow("| :--- | :---: | ---: |")
        XCTAssertEqual(aligns, [.leading, .center, .trailing])
    }

    func testParseDelimiterRowRejectsNonDashCells() {
        XCTAssertNil(MarkdownRenderer.parseDelimiterRow("| --- | abc |"))
    }

    // MARK: - Row splitting

    func testSplitRowTrimsAndDropsBorderPipes() {
        XCTAssertEqual(MarkdownRenderer.splitRow("|  a  |  b  |"), ["a", "b"])
        XCTAssertEqual(MarkdownRenderer.splitRow("a | b | c"), ["a", "b", "c"])
    }

    // MARK: - Rendering integration

    func testRenderTableProducesTextTableParagraphs() {
        let markdown = """
        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let attributed = MarkdownRenderer.render(markdown)
        // The raw delimiter row must not survive into the rendered output.
        XCTAssertFalse(attributed.string.contains("---"))
        // Cells should carry a paragraph style backed by an NSTextTableBlock.
        var sawTableBlock = false
        attributed.enumerateAttribute(.paragraphStyle, in: NSRange(location: 0, length: attributed.length)) { value, _, _ in
            if let style = value as? NSParagraphStyle, !style.textBlocks.isEmpty {
                sawTableBlock = true
            }
        }
        XCTAssertTrue(sawTableBlock)
        XCTAssertTrue(attributed.string.contains("A"))
        XCTAssertTrue(attributed.string.contains("2"))
    }

    func testRenderLeavesNonTableContentIntact() {
        let attributed = MarkdownRenderer.render("# Heading\n\nplain line")
        XCTAssertTrue(attributed.string.contains("Heading"))
        XCTAssertTrue(attributed.string.contains("plain line"))
    }

    /// Every character must carry a foreground color. An unattributed run (the newline
    /// separators used to leak one) draws black no matter the appearance, and it also
    /// infects raw edit mode, which inherits the first character's attributes.
    func testEveryCharacterCarriesAForegroundColor() {
        let markdown = """

        # Heading
        body **bold** text
        - bullet
        - [x] done
        | A | B |
        | --- | --- |
        | 1 | 2 |
        """
        let attributed = MarkdownRenderer.render(markdown)
        XCTAssertGreaterThan(attributed.length, 0)

        var uncolored: [NSRange] = []
        attributed.enumerateAttribute(.foregroundColor,
                                      in: NSRange(location: 0, length: attributed.length)) { value, range, _ in
            if value as? NSColor == nil { uncolored.append(range) }
        }
        XCTAssertTrue(uncolored.isEmpty, "runs without a foreground color: \(uncolored)")
    }

    /// A note that starts with a blank line renders a separator as its first character;
    /// that character has to be colored, since edit mode copies its attributes.
    func testLeadingBlankLineIsColored() {
        let attributed = MarkdownRenderer.render("\nfirst real line")
        let first = attributed.attributes(at: 0, effectiveRange: nil)
        XCTAssertEqual(first[.foregroundColor] as? NSColor, NSColor.labelColor)
        XCTAssertNotNil(first[.font] as? NSFont)
    }

    // MARK: - Task source-line mapping

    /// Collect (sourceLine, characterOffset) for every distinct task run in a rendered string.
    private func taskSourceLines(_ rendered: NSAttributedString) -> [(line: Int, offset: Int)] {
        var found: [(line: Int, offset: Int)] = []
        rendered.enumerateAttribute(.tqTaskSourceLine,
                                    in: NSRange(location: 0, length: rendered.length)) { value, range, _ in
            guard let line = value as? Int else { return }
            if found.last?.line != line { found.append((line, range.location)) }
        }
        return found
    }

    func testTaskLinesCarryTheirSourceLineIndex() {
        let rendered = MarkdownRenderer.render("- [ ] a\n- [x] b")
        XCTAssertEqual(taskSourceLines(rendered).map(\.line), [0, 1])
    }

    /// The reason the mapping is an attribute rather than arithmetic: a table collapses several
    /// source lines into one rendered block, so rendered position and source line diverge.
    func testTaskSourceLineSurvivesATableAbove() {
        let markdown = [
            "| Name | Age |",
            "| --- | --- |",
            "| Ada | 36 |",
            "| Alan | 41 |",
            "",
            "- [ ] first",
            "- [x] second",
        ].joined(separator: "\n")

        let rendered = MarkdownRenderer.render(markdown)
        let tasks = taskSourceLines(rendered)

        XCTAssertEqual(tasks.map(\.line), [5, 6])
        // Guard against a coincidental pass: the source lines must not equal the rendered
        // character offsets, which is exactly what naive index arithmetic would produce.
        for task in tasks {
            XCTAssertNotEqual(task.line, task.offset)
        }
    }

    func testTaskCheckboxAttributeCoversOnlyTheGutterAndBox() {
        for (markdown, expected) in [("- [ ] a", "  \u{2610} "), ("- [x] a", "  \u{2611} ")] {
            let rendered = MarkdownRenderer.render(markdown)
            var range = NSRange(location: 0, length: 0)
            let value = rendered.attribute(.tqTaskCheckbox, at: 0, effectiveRange: &range)
            XCTAssertNotNil(value)
            XCTAssertEqual(range.length, 4)
            XCTAssertEqual((rendered.string as NSString).substring(with: range), expected)
        }
    }

    func testNonTaskLinesCarryNoTaskAttributes() {
        let rendered = MarkdownRenderer.render("# Heading\n- bullet\n1. numbered\nprose")
        let full = NSRange(location: 0, length: rendered.length)

        var sawTaskAttribute = false
        rendered.enumerateAttribute(.tqTaskSourceLine, in: full) { value, _, _ in
            if value != nil { sawTaskAttribute = true }
        }
        rendered.enumerateAttribute(.tqTaskCheckbox, in: full) { value, _, _ in
            if value != nil { sawTaskAttribute = true }
        }
        XCTAssertFalse(sawTaskAttribute)
    }

    func testEmptyTaskLineStillRendersACheckbox() {
        // The state an emptied item is left in; without the relaxed parse it would render as a
        // bullet reading "[ ]".
        XCTAssertEqual(MarkdownRenderer.render("- [ ]").string, "  \u{2610} ")
        XCTAssertEqual(MarkdownRenderer.render("- [ ] ").string, "  \u{2610} ")
    }
}
