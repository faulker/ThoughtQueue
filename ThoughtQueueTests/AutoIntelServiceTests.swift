import XCTest
@testable import ThoughtQueue

/// Covers the category-reuse logic that keeps auto-intel from spawning near-duplicate
/// folders when the on-device model proposes a category that already exists.
final class AutoIntelServiceTests: XCTestCase {

    func testMatchesExistingCategoryCaseInsensitively() {
        let existing = ["Work", "Personal", "Ideas"]
        // Lowercased proposal snaps onto the existing folder's exact spelling.
        XCTAssertEqual(AutoIntelService.matchExistingCategory("work", in: existing), "Work")
        XCTAssertEqual(AutoIntelService.matchExistingCategory("PERSONAL", in: existing), "Personal")
    }

    func testKeepsExactExistingSpelling() {
        let existing = ["Work", "Personal"]
        XCTAssertEqual(AutoIntelService.matchExistingCategory("Work", in: existing), "Work")
    }

    func testReturnsProposalWhenNoMatch() {
        let existing = ["Work", "Personal"]
        // Genuinely new category is preserved verbatim so it can be created.
        XCTAssertEqual(AutoIntelService.matchExistingCategory("Travel", in: existing), "Travel")
    }

    func testReturnsProposalWhenNoCategoriesExist() {
        XCTAssertEqual(AutoIntelService.matchExistingCategory("Anything", in: []), "Anything")
    }
}
