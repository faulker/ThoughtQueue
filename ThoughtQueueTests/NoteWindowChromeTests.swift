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

    func testNavigatorPutsArchivedGroupsAtTheBottomWithAFlag() throws {
        _ = try XCTUnwrap(NoteStore.shared.createNote(title: "Live", body: "x", category: "Work"))
        _ = try XCTUnwrap(NoteStore.shared.createNote(title: "Old", body: "x", category: "Done"))
        _ = try XCTUnwrap(NoteStore.shared.createNote(title: "Loose", body: "x", category: nil))
        XCTAssertTrue(NoteStore.shared.setArchived(true, category: "Done"))

        let navigator = NoteNavigatorViewController()
        _ = navigator.view

        XCTAssertEqual(navigator.groupNames, ["Work", Note.uncategorized, "Done"])
        XCTAssertEqual(navigator.archivedGroupNames, ["Done"])
    }

    func testNewNoteMenuReportsCategoryAndType() throws {
        let navigator = NoteNavigatorViewController()
        _ = navigator.view
        var created: [(String?, NoteDocType)] = []
        navigator.onCreateNote = { created.append(($0, $1)) }
        for item in navigator.newNoteItems(category: "Work") {
            _ = navigator.perform(item.action, with: item)
        }
        XCTAssertEqual(created.map(\.0), ["Work", "Work"])
        XCTAssertEqual(created.map(\.1), [.markdown, .checklist])
    }

    func testNewNotesFollowTheShownNotesFolderUnlessArchived() throws {
        let note = try XCTUnwrap(NoteStore.shared.createNote(title: "Live", body: "x", category: "Work"))
        let navigator = NoteNavigatorViewController()
        navigator.highlight(note: note)
        XCTAssertEqual(navigator.defaultNewNoteCategory, "Work")
        XCTAssertTrue(NoteStore.shared.setArchived(true, category: "Work"))
        XCTAssertNil(navigator.defaultNewNoteCategory)
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

    func testPreferencesIsSplitIntoToolbarPanes() throws {
        let controller = PreferencesWindowController()
        defer { controller.window?.close() }

        let tabs = try XCTUnwrap(controller.window?.contentViewController as? NSTabViewController)
        XCTAssertEqual(tabs.tabStyle, .toolbar)
        XCTAssertEqual(tabs.tabViewItems.map(\.label), ["General", "Appearance", "Notes", "Capture", "Storage & Sync"])
        XCTAssertEqual(tabs.tabViewItems.map(\.label), PreferencesWindowController.Pane.allCases.map(\.title))
        for item in tabs.tabViewItems {
            XCTAssertNotNil(item.image, "\(item.label) needs a toolbar icon")
        }
    }
}
