import XCTest
import AppKit
@testable import ThoughtQueue

/// What Cmd+Q does for each preference, and that quitting saves open notes.
final class QuitCommandTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("tq-quit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        NoteStore.shared.rootURL = root
    }

    override func tearDownWithError() throws {
        NoteWindowController.closeAllForTesting()
        try? FileManager.default.removeItem(at: root)
        NoteStore.shared.rootURL = nil
    }

    /// Opens a new note window and types `text` into it without saving.
    private func openNote(typing text: String) throws -> Note {
        let note = try XCTUnwrap(NoteWindowController.showNew())
        let editor = try XCTUnwrap(NSApp.windows.compactMap(\.noteEditor).first { $0.currentNote.url == note.url })
        editor.textView.insertText(text, replacementRange: NSRange(location: 0, length: 0))
        return note
    }

    func testQuittingSavesEveryOpenNote() throws {
        let first = try openNote(typing: "one")
        let second = try openNote(typing: "two")
        XCTAssertEqual(NoteStore.shared.body(of: first), "", "still unsaved before quitting")

        XCTAssertEqual(AppDelegate().applicationShouldTerminate(NSApp), .terminateNow)
        XCTAssertEqual(NoteStore.shared.body(of: first), "one")
        XCTAssertEqual(NoteStore.shared.body(of: second), "two")
    }

    func testQuittingSavesAPendingChecklistEdit() throws {
        let note = try XCTUnwrap(NoteWindowController.showNew(body: TaskList.newItemPrefix, docType: .checklist))
        let editor = try XCTUnwrap(NSApp.windows.compactMap(\.noteEditor).first { $0.currentNote.url == note.url })
        let responder = try XCTUnwrap(editor.view.window?.firstResponder as? NSTextView)
        responder.insertText("milk", replacementRange: responder.selectedRange())

        XCTAssertEqual(NoteWindowController.saveAllBeforeQuit(), [])
        XCTAssertTrue(NoteStore.shared.body(of: note).contains("milk"))
    }

    func testAFailedSaveIsReportedAndStaysUnsaved() throws {
        let note = try openNote(typing: "lost?")
        try FileManager.default.removeItem(at: note.url)
        XCTAssertEqual(NoteWindowController.saveAllBeforeQuit(), [note.title])
        XCTAssertEqual(NoteWindowController.saveAllBeforeQuit(), [note.title], "a failure must not mark the note saved")
    }

    func testKeyboardFollowsThePreference() {
        XCTAssertEqual(AppDelegate.quitDecision(action: .quit, confirm: true, fromKeyboard: true), .confirmThenQuit)
        XCTAssertEqual(AppDelegate.quitDecision(action: .quit, confirm: false, fromKeyboard: true), .quit)
        XCTAssertEqual(AppDelegate.quitDecision(action: .closeNote, confirm: true, fromKeyboard: true), .closeFrontWindow)
        XCTAssertEqual(AppDelegate.quitDecision(action: .nothing, confirm: true, fromKeyboard: true), .ignore)
    }

    func testClickingTheMenuItemAlwaysQuits() {
        for action in CmdQAction.allCases {
            XCTAssertEqual(AppDelegate.quitDecision(action: action, confirm: true, fromKeyboard: false), .quit)
        }
    }

    func testDefaultsAreQuitWithConfirmation() {
        let defaults = UserDefaults.standard
        let saved = ["cmdQAction", "confirmQuit"].map { ($0, defaults.object(forKey: $0)) }
        defer { saved.forEach { defaults.set($0.1, forKey: $0.0) } }
        saved.forEach { defaults.removeObject(forKey: $0.0) }
        XCTAssertEqual(PreferencesManager.shared.cmdQAction, .quit)
        XCTAssertTrue(PreferencesManager.shared.confirmQuit)
    }
}
