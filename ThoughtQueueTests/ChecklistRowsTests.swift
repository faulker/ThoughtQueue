import XCTest
@testable import ThoughtQueue

/// Covers the row model behind the checklist editor. The invariant everything else depends on:
/// decomposing a body into rows and reassembling it returns the original bytes, so editing one
/// item can never disturb the rest of the file.
final class ChecklistRowsTests: XCTestCase {

    // MARK: - Round trip

    private func assertRoundTrips(_ body: String, file: StaticString = #filePath, line: UInt = #line) {
        let rebuilt = TaskList.body(from: TaskList.rows(from: body))
        XCTAssertEqual(rebuilt, body, "round trip changed \(body.debugDescription)", file: file, line: line)
    }

    func testRoundTripAcrossRepresentativeBodies() {
        let bodies = [
            "",
            "\n",
            "- [ ] a",
            "- [ ] a\n",
            "# Groceries\n\n- [ ] milk\n- [x] eggs\n\n",
            "\t  * [X]   spaced   text  \n",
            "- [ ]",
            "- [ ] ",
            "+ [x] plus bullet\n",
            "- [ ] a\r\n- [ ] b\r\n",
            "- [ ] lf\n- [ ] crlf\r\n",
            "#tag\n- [ ] a\n",
            "   \n- [ ] a",
            "###### deep heading\n- [ ] a\n",
            "just prose\n\nmore prose\n",
            "| a | b |\n| --- | --- |\n",
            "- bullet\n1. numbered\n",
        ]
        for body in bodies { assertRoundTrips(body) }
    }

    /// The reconstruct-and-compare fallback exists so unanticipated inputs round-trip too.
    func testRoundTripFuzz() {
        let alphabet = [
            "- [ ] item", "- [x] done", "* [X] star", "+ [ ] plus", "  - [ ] indented",
            "\t- [ ] tabbed", "- [ ]", "- [ ]   padded  ", "# Heading", "### Deep",
            "#tag", "", "   ", "\t", "prose line", "- bullet", "1. numbered",
            "| a | b |", "---", "> quote", "```", "- [y] bad marker", "- [x]nospace",
        ]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<200 {
            let count = Int.random(in: 0...12, using: &generator)
            var lines: [String] = []
            for _ in 0..<count {
                var line = alphabet.randomElement(using: &generator)!
                if Bool.random(using: &generator) { line += "\r" }
                lines.append(line)
            }
            assertRoundTrips(lines.joined(separator: "\n"))
        }
    }

    // MARK: - Classification

    func testTaskRowKeepsEveryPieceVerbatim() throws {
        let row = TaskList.row(from: "\t  * [X]   spaced   text  ")
        guard case .task(let task) = row.kind else { return XCTFail("expected a task row") }

        XCTAssertEqual(task.indent, "\t  ")
        XCTAssertEqual(task.bullet, "*")
        XCTAssertEqual(task.spacing, " ")
        XCTAssertEqual(task.marker, "X")
        XCTAssertTrue(task.checked)
        XCTAssertEqual(task.indent + String(task.bullet) + task.spacing + "[" + String(task.marker) + "]"
                       + task.gap + task.text, "\t  * [X]   spaced   text  ")
    }

    func testHeadingBlankAndOtherRows() {
        guard case .heading(let heading) = TaskList.row(from: "## Fruit").kind else {
            return XCTFail("expected a heading row")
        }
        XCTAssertEqual(heading.level, 2)
        XCTAssertEqual(heading.text, "Fruit")

        XCTAssertTrue(TaskList.row(from: "   ").isBlank)
        XCTAssertTrue(TaskList.row(from: "").isBlank)

        // "#tag" has no space after the hashes, so it is not an ATX heading.
        if case .other = TaskList.row(from: "#tag").kind {} else { XCTFail("expected other") }
        if case .other = TaskList.row(from: "- bullet").kind {} else { XCTFail("expected other") }
    }

    func testCarriageReturnIsPreserved() {
        let row = TaskList.row(from: "- [ ] a\r")
        XCTAssertTrue(row.carriageReturn)
        XCTAssertEqual(TaskList.line(from: row), "- [ ] a\r")
    }

    // MARK: - Mutators

    func testNewTaskRowInheritsBulletIndentAndLineEnding() throws {
        let template = TaskList.row(from: "  * [x] a\r")
        let fresh = TaskList.newTaskRow(like: template)

        guard case .task(let task) = fresh.kind else { return XCTFail("expected a task row") }
        XCTAssertEqual(task.indent, "  ")
        XCTAssertEqual(task.bullet, "*")
        XCTAssertFalse(task.checked)
        XCTAssertEqual(task.text, "")
        XCTAssertTrue(fresh.carriageReturn)
    }

    func testSettingCheckedWritesLowercaseAndChangesNothingElse() {
        let rows = TaskList.rows(from: "\t  * [ ]   spaced   text  ")
        let updated = TaskList.settingChecked(true, at: 0, in: rows)
        XCTAssertEqual(TaskList.body(from: updated), "\t  * [x]   spaced   text  ")
    }

    func testSplitThenMergeIsIdentity() {
        let rows = TaskList.rows(from: "- [ ] hello world\n- [ ] second\n")
        let split = TaskList.splittingTask(at: 0, offset: 5, in: rows)
        XCTAssertEqual(TaskList.body(from: split.rows), "- [ ] hello\n- [ ]  world\n- [ ] second\n")

        let merged = TaskList.mergingRowIntoPrevious(at: split.focusRow, in: split.rows)
        XCTAssertEqual(TaskList.body(from: merged.rows), "- [ ] hello world\n- [ ] second\n")
        XCTAssertEqual(merged.focusRow, 0)
        XCTAssertEqual(merged.focusOffset, 5)
    }

    func testMergingAfterAHeadingIsANoOp() {
        let rows = TaskList.rows(from: "# Groceries\n- [ ] milk\n")
        let merged = TaskList.mergingRowIntoPrevious(at: 1, in: rows)
        XCTAssertEqual(TaskList.body(from: merged.rows), "# Groceries\n- [ ] milk\n")
    }

    func testDeletingTheLastTaskSubstitutesAFreshEmptyOne() {
        let rows = TaskList.rows(from: "- [x] only")
        let edit = TaskList.deletingRow(at: 0, in: rows)

        XCTAssertEqual(TaskList.body(from: edit.rows), "- [ ] ")
        XCTAssertTrue(TaskList.isChecklist(TaskList.body(from: edit.rows)),
                      "a list must never stop being a list mid-typing")
    }

    func testDeletingFocusesTheEndOfThePreviousRow() {
        let rows = TaskList.rows(from: "- [ ] first\n- [ ] second\n")
        let edit = TaskList.deletingRow(at: 1, in: rows)

        XCTAssertEqual(TaskList.body(from: edit.rows), "- [ ] first\n")
        XCTAssertEqual(edit.focusRow, 0)
        XCTAssertEqual(edit.focusOffset, "first".count)
    }

    func testInsertingTaskInheritsAndFocusesTheNewRow() {
        let rows = TaskList.rows(from: "  * [x] a\n")
        let edit = TaskList.insertingTask(after: 0, in: rows)

        XCTAssertEqual(TaskList.body(from: edit.rows), "  * [x] a\n  * [ ] \n")
        XCTAssertEqual(edit.focusRow, 1)
        XCTAssertEqual(edit.focusOffset, 0)
    }

    func testAppendAnchorSkipsTrailingBlanks() {
        let rows = TaskList.rows(from: "- [ ] a\n- [ ] b\n")   // trailing newline -> final blank row
        XCTAssertEqual(TaskList.appendAnchor(in: rows), 1)

        let edit = TaskList.insertingTask(after: TaskList.appendAnchor(in: rows), in: rows)
        XCTAssertEqual(TaskList.body(from: edit.rows), "- [ ] a\n- [ ] b\n- [ ] \n",
                       "a new item must not be pushed past the file's trailing newline")
    }

    func testSettingTextGivesABareItemItsSeparator() {
        let rows = TaskList.rows(from: "- [ ]")
        let updated = TaskList.settingText("milk", at: 0, in: rows)
        XCTAssertEqual(TaskList.body(from: updated), "- [ ] milk")
    }
}
