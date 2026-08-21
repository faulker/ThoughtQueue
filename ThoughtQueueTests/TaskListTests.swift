import XCTest
@testable import ThoughtQueue

/// Covers the pure task-line logic behind checklists. The invariant that matters throughout:
/// rewriting a marker changes the marker and nothing else, so a note's bullets, indentation,
/// spacing, trailing content, and line endings survive a toggle untouched.
final class TaskListTests: XCTestCase {

    // MARK: - Single-line toggling

    func testToggleUncheckedToChecked() {
        XCTAssertEqual(TaskList.toggled("- [ ] milk"), "- [x] milk")
    }

    func testToggleCheckedToUnchecked() {
        XCTAssertEqual(TaskList.toggled("- [x] milk"), "- [ ] milk")
    }

    func testUppercaseMarkerIsRecognizedAndWrittenBackLowercase() {
        XCTAssertEqual(TaskList.toggled("- [X] milk"), "- [ ] milk")
        XCTAssertEqual(TaskList.parse("- [X] milk")?.checked, true)
    }

    func testBulletCharacterIsPreserved() {
        XCTAssertEqual(TaskList.toggled("* [ ] milk"), "* [x] milk")
        XCTAssertEqual(TaskList.toggled("+ [ ] milk"), "+ [x] milk")
    }

    func testIndentationIsPreserved() {
        XCTAssertEqual(TaskList.toggled("\t  - [ ] milk"), "\t  - [x] milk")
    }

    func testSpacingAndTrailingContentSurviveVerbatim() {
        let line = "-   [ ]   spaced   text  "
        XCTAssertEqual(TaskList.toggled(line), "-   [x]   spaced   text  ")
    }

    func testEmptyItemParsesWithOrWithoutTrailingSpace() {
        XCTAssertNotNil(TaskList.parse("- [ ] "))
        XCTAssertNotNil(TaskList.parse("- [ ]"))
        XCTAssertEqual(TaskList.parse("- [ ]")?.text, "")
    }

    func testNonTaskLinesReturnNil() {
        for line in ["", "plain", "- bullet", "# head", "[ ] no bullet", "- [y] a", "- [x]nospace"] {
            XCTAssertNil(TaskList.toggled(line), "expected nil for \(line.debugDescription)")
            XCTAssertFalse(TaskList.isTaskLine(line), "expected non-task for \(line.debugDescription)")
        }
    }

    // MARK: - Body-level toggling

    func testTogglingOneLineLeavesEveryOtherLineByteIdentical() throws {
        let body = "# Groceries\n\n- [ ] milk\n- [x] eggs\n\nnote at the end\n"
        let updated = try XCTUnwrap(TaskList.toggle(body: body, lineIndex: 2))

        XCTAssertEqual(updated, "# Groceries\n\n- [x] milk\n- [x] eggs\n\nnote at the end\n")
        // Same line count, so the trailing newline round-tripped rather than being eaten.
        XCTAssertEqual(updated.components(separatedBy: "\n").count,
                       body.components(separatedBy: "\n").count)
    }

    func testOutOfRangeAndNonTaskIndicesReturnNil() {
        let body = "# Groceries\n- [ ] milk\n"
        XCTAssertNil(TaskList.toggle(body: body, lineIndex: 0))   // heading
        XCTAssertNil(TaskList.toggle(body: body, lineIndex: 99))  // out of range
        XCTAssertNil(TaskList.toggle(body: body, lineIndex: -1))
    }

    func testCRLFLineEndingsSurvive() throws {
        let body = "- [ ] a\r\n- [ ] b\r\n"
        let updated = try XCTUnwrap(TaskList.toggle(body: body, lineIndex: 0))
        XCTAssertEqual(updated, "- [x] a\r\n- [ ] b\r\n")
    }

    func testDoubleToggleRoundTrips() throws {
        let body = "- [ ] a\n- [x] b\n"
        let once = try XCTUnwrap(TaskList.toggle(body: body, lineIndex: 0))
        let twice = try XCTUnwrap(TaskList.toggle(body: once, lineIndex: 0))
        XCTAssertEqual(twice, body)
    }

    func testIsCheckedReadsTheMarker() {
        let body = "- [ ] a\n- [x] b\nprose\n"
        XCTAssertEqual(TaskList.isChecked(body: body, lineIndex: 0), false)
        XCTAssertEqual(TaskList.isChecked(body: body, lineIndex: 1), true)
        XCTAssertNil(TaskList.isChecked(body: body, lineIndex: 2))
    }

    func testToggleOrPromoteTurnsProseIntoATask() throws {
        let body = "buy milk\n"
        XCTAssertEqual(try XCTUnwrap(TaskList.toggleOrPromote(body: body, lineIndex: 0)), "- [ ] buy milk\n")
    }

    func testToggleOrPromoteReusesAnExistingBullet() throws {
        let body = "- buy milk\n"
        XCTAssertEqual(try XCTUnwrap(TaskList.toggleOrPromote(body: body, lineIndex: 0)), "- [ ] buy milk\n")
    }

    func testToggleOrPromoteFlipsAnExistingTask() throws {
        let body = "- [ ] buy milk\n"
        XCTAssertEqual(try XCTUnwrap(TaskList.toggleOrPromote(body: body, lineIndex: 0)), "- [x] buy milk\n")
    }

    // MARK: - Return key

    func testReturnContinuesAList() {
        XCTAssertEqual(TaskList.returnAction(for: "- [ ] item"), .continueList(prefix: "- [ ] "))
    }

    func testReturnContinuationIsAlwaysUncheckedAndKeepsBulletAndIndent() {
        XCTAssertEqual(TaskList.returnAction(for: "  * [x] item"), .continueList(prefix: "  * [ ] "))
    }

    func testReturnOnAnEmptyItemClearsTheMarker() {
        XCTAssertEqual(TaskList.returnAction(for: "- [ ] "), .clearMarker)
        XCTAssertEqual(TaskList.returnAction(for: "- [ ]"), .clearMarker)
    }

    func testReturnPassesThroughOnProseAndPlainBullets() {
        XCTAssertEqual(TaskList.returnAction(for: "prose"), .pass)
        XCTAssertEqual(TaskList.returnAction(for: "- bullet"), .pass)
        XCTAssertEqual(TaskList.returnAction(for: ""), .pass)
    }

    // MARK: - Checklist classification

    func testIsChecklistAcceptsAPureListAndAHeadedList() {
        XCTAssertTrue(TaskList.isChecklist("- [ ] a\n- [x] b\n"))
        XCTAssertTrue(TaskList.isChecklist("# Groceries\n\n- [ ] milk\n\n"))
    }

    func testIsChecklistRejectsProseAndMixedDocuments() {
        XCTAssertFalse(TaskList.isChecklist(""))
        XCTAssertFalse(TaskList.isChecklist("just prose"))
        XCTAssertFalse(TaskList.isChecklist("- [ ] a\nsome prose"))
        XCTAssertFalse(TaskList.isChecklist("- [ ] a\n  continuation notes"))
        XCTAssertFalse(TaskList.isChecklist("- bullet\n- bullet"))
    }
}
