import XCTest
import AppKit
@testable import ThoughtQueue

final class PreferencesManagerTests: XCTestCase {

    func testResolveEditorFontWithValidNameAndSize() {
        let font = PreferencesManager.resolveEditorFont(name: "Helvetica", size: 18)
        XCTAssertEqual(font.fontName, "Helvetica")
        XCTAssertEqual(font.pointSize, 18, accuracy: 0.001)
    }

    func testResolveEditorFontFallsBackOnNilName() {
        let font = PreferencesManager.resolveEditorFont(name: nil, size: 20)
        XCTAssertEqual(font.pointSize, 20, accuracy: 0.001)
        XCTAssertEqual(font, NSFont.systemFont(ofSize: 20))
    }

    func testResolveEditorFontFallsBackOnUnknownName() {
        let font = PreferencesManager.resolveEditorFont(name: "NotARealFont-XYZ", size: 14)
        XCTAssertEqual(font, NSFont.systemFont(ofSize: 14))
    }

    func testResolveEditorFontUsesDefaultSizeWhenZero() {
        let font = PreferencesManager.resolveEditorFont(name: nil, size: 0)
        XCTAssertEqual(font.pointSize, PreferencesManager.defaultEditorFontSize, accuracy: 0.001)
    }

    func testNoteWindowSizeDefaultsWhenUnset() {
        let defaults = UserDefaults.standard
        let savedW = defaults.object(forKey: "noteWindowWidth")
        let savedH = defaults.object(forKey: "noteWindowHeight")
        defer {
            defaults.set(savedW, forKey: "noteWindowWidth")
            defaults.set(savedH, forKey: "noteWindowHeight")
        }
        defaults.removeObject(forKey: "noteWindowWidth")
        defaults.removeObject(forKey: "noteWindowHeight")

        XCTAssertEqual(PreferencesManager.shared.noteWindowSize, PreferencesManager.defaultNoteWindowSize)
    }

    func testNoteWindowSizeRoundTrips() {
        let saved = PreferencesManager.shared.noteWindowSize
        defer { PreferencesManager.shared.noteWindowSize = saved }

        let size = NSSize(width: 640, height: 700)
        PreferencesManager.shared.noteWindowSize = size
        XCTAssertEqual(PreferencesManager.shared.noteWindowSize, size)
    }

    func testNoteNavigatorWidthDefaultsWhenUnset() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "noteNavigatorWidth")
        defer { defaults.set(saved, forKey: "noteNavigatorWidth") }
        defaults.removeObject(forKey: "noteNavigatorWidth")

        XCTAssertEqual(PreferencesManager.shared.noteNavigatorWidth, PreferencesManager.defaultNoteNavigatorWidth)
    }

    func testNoteNavigatorWidthRoundTripsAndClamps() {
        let saved = PreferencesManager.shared.noteNavigatorWidth
        defer { PreferencesManager.shared.noteNavigatorWidth = saved }

        PreferencesManager.shared.noteNavigatorWidth = 240
        XCTAssertEqual(PreferencesManager.shared.noteNavigatorWidth, 240)

        // Outside the split view item's allowed thickness range, values clamp instead of sticking.
        PreferencesManager.shared.noteNavigatorWidth = 900
        XCTAssertEqual(PreferencesManager.shared.noteNavigatorWidth, 320)
        PreferencesManager.shared.noteNavigatorWidth = 40
        XCTAssertEqual(PreferencesManager.shared.noteNavigatorWidth, 160)
    }

    func testNoteAlwaysOnTopRoundTripsAndPostsNotification() {
        let saved = PreferencesManager.shared.noteAlwaysOnTop
        defer { PreferencesManager.shared.noteAlwaysOnTop = saved }

        let expectation = expectation(forNotification: .noteAlwaysOnTopDidChange, object: nil)
        PreferencesManager.shared.noteAlwaysOnTop = true
        XCTAssertTrue(PreferencesManager.shared.noteAlwaysOnTop)
        wait(for: [expectation], timeout: 1)

        PreferencesManager.shared.noteAlwaysOnTop = false
        XCTAssertFalse(PreferencesManager.shared.noteAlwaysOnTop)
    }
}
