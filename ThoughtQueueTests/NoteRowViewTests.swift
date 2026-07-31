import XCTest
import AppKit
@testable import ThoughtQueue

/// Verifies the popover note row exposes generously sized (padded) action buttons, so a click
/// landing a few pixels off an icon still hits its button rather than the row's open action.
@MainActor
final class NoteRowViewTests: XCTestCase {

    private func makeNote() -> Note {
        Note(
            url: URL(fileURLWithPath: "/tmp/tq-row-test/Example.md"),
            title: "Example",
            category: nil,
            createdAt: Date(),
            modifiedAt: Date()
        )
    }

    /// Collect every NSButton in a view tree.
    private func buttons(in view: NSView) -> [NSButton] {
        var found: [NSButton] = []
        for sub in view.subviews {
            if let btn = sub as? NSButton { found.append(btn) }
            found.append(contentsOf: buttons(in: sub))
        }
        return found
    }

    func testActionButtonsHavePaddedHitTargets() {
        let row = NoteRowView(note: makeNote(), compact: false) {}
        row.frame = NSRect(x: 0, y: 0, width: 320, height: 44)
        row.layoutSubtreeIfNeeded()

        let btns = buttons(in: row)
        XCTAssertEqual(btns.count, 5, "row should offer five action buttons")
        // The 28pt constraints pin each button's alignment rect; its clickable frame is at
        // least that (larger once a borderless symbol's alignment insets are added), so a
        // near-miss click still lands on the button rather than the row.
        for btn in btns {
            XCTAssertGreaterThanOrEqual(btn.frame.width, 28, "each button should be a padded hit target")
            XCTAssertGreaterThanOrEqual(btn.frame.height, 28, "each button should be a padded hit target")
        }
    }

    /// Popover rows expose Clone instead of Move-to-category among the hover actions.
    func testActionButtonsIncludeCloneNotMoveCategory() {
        let row = NoteRowView(note: makeNote(), compact: false) {}
        let tips = Set(buttons(in: row).compactMap(\.toolTip))
        XCTAssertTrue(tips.contains("Clone note"))
        XCTAssertFalse(tips.contains("Move to category\u{2026}"))
    }
}
