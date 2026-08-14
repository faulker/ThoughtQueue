import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers two pieces of window chrome: the note navigator having its content ready the moment
/// its view exists (it used to render blank if anything revealed the panel before the first
/// explicit reload), and Preferences floating above the app's other windows.
final class NoteWindowChromeTests: XCTestCase {
    private var tempRoot: URL!

    override func setUpWithError() throws {
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("tq-chrome-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = tempRoot
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempRoot)
        NoteStore.shared.rootURL = nil
    }

    func testNavigatorHasContentAsSoonAsItsViewLoads() throws {
        _ = try XCTUnwrap(NoteStore.shared.createNote(title: "Visible", body: "body", category: "Work"))

        let navigator = NoteNavigatorViewController()
        _ = navigator.view // no explicit reload(), as when the panel is revealed by AppKit

        XCTAssertGreaterThan(navigator.rowCount, 0)
    }

    func testNavigatorReloadStillPicksUpLaterNotes() throws {
        let navigator = NoteNavigatorViewController()
        _ = navigator.view
        let before = navigator.rowCount

        _ = try XCTUnwrap(NoteStore.shared.createNote(title: "Later", body: "body", category: "Work"))
        navigator.reload()

        XCTAssertGreaterThan(navigator.rowCount, before)
    }

    func testPreferencesFloatsAbovePinnedNotesButBelowOverlayLevel() {
        XCTAssertGreaterThan(PreferencesWindowController.level.rawValue, NoteWindowController.pinnedLevel.rawValue)
        XCTAssertGreaterThan(NoteWindowController.pinnedLevel.rawValue, NSWindow.Level.normal.rawValue)
        XCTAssertLessThan(PreferencesWindowController.level.rawValue, NSWindow.Level.floating.rawValue)
    }

    func testPreferencesWindowUsesThatLevel() {
        let controller = PreferencesWindowController()
        defer { controller.window?.close() }

        XCTAssertEqual(controller.window?.level, PreferencesWindowController.level)
        XCTAssertTrue(controller.window?.collectionBehavior.contains(.moveToActiveSpace) ?? false)
    }
}
