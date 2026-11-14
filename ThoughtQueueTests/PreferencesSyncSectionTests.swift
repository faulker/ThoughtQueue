import XCTest
@testable import ThoughtQueue

/// The pure rules behind the Preferences Sync section.
final class PreferencesSyncSectionTests: XCTestCase {
    func testIntervalChoicesMapToSeconds() {
        XCTAssertEqual(PreferencesWindowController.syncIntervalChoices.map(\.seconds), [60, 300, 900, 1800, 3600])
        XCTAssertEqual(PreferencesWindowController.syncIntervalIndex(for: 300), 1)
        XCTAssertEqual(PreferencesWindowController.syncIntervalIndex(for: 3600), 4)
    }

    func testOddIntervalSnapsToNearestChoice() {
        XCTAssertEqual(PreferencesWindowController.syncIntervalIndex(for: 30), 0)
        XCTAssertEqual(PreferencesWindowController.syncIntervalIndex(for: 800), 2)
        XCTAssertEqual(PreferencesWindowController.syncIntervalIndex(for: 99_999), 4)
    }

    func testEnablementRulesPerMode() {
        XCTAssertFalse(PreferencesWindowController.s3ControlsEnabled(for: .local))
        XCTAssertTrue(PreferencesWindowController.s3ControlsEnabled(for: .s3))
        XCTAssertTrue(PreferencesWindowController.s3ControlsEnabled(for: .both))
        XCTAssertTrue(PreferencesWindowController.storeFolderEnabled(for: .local))
        XCTAssertFalse(PreferencesWindowController.storeFolderEnabled(for: .s3))
        XCTAssertTrue(PreferencesWindowController.storeFolderEnabled(for: .both))
    }

    func testModeChoicesCoverEveryMode() {
        XCTAssertEqual(Set(PreferencesWindowController.storageModeChoices.map(\.mode)), Set(StorageMode.allCases))
    }

    func testStatusText() {
        XCTAssertEqual(PreferencesWindowController.syncStatusText(status: .syncing, lastSync: nil), "Syncing\u{2026}")
        XCTAssertEqual(PreferencesWindowController.syncStatusText(status: .error("boom"), lastSync: Date()), "boom")
        XCTAssertEqual(PreferencesWindowController.syncStatusText(status: .idle, lastSync: nil), "Not synced yet")
        XCTAssertTrue(PreferencesWindowController.syncStatusText(status: .idle, lastSync: Date()).hasPrefix("Last synced "))
    }
}
