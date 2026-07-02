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
}
