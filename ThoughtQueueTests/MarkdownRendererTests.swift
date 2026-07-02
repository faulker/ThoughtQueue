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
}
