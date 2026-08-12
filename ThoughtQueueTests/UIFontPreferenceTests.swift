import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers the interface-font preference: the stored family/scale values and how `Theme`
/// resolves them into fonts and layout metrics.
final class UIFontPreferenceTests: XCTestCase {

    private let defaults = UserDefaults.standard

    override func tearDownWithError() throws {
        defaults.removeObject(forKey: "uiFontFamily")
        defaults.removeObject(forKey: "uiFontScale")
    }

    // MARK: - Stored values

    func testUIFontDefaultsToBundledFamilyAndUnityScale() {
        defaults.removeObject(forKey: "uiFontFamily")
        defaults.removeObject(forKey: "uiFontScale")

        XCTAssertNil(PreferencesManager.shared.uiFontFamily)
        XCTAssertEqual(PreferencesManager.shared.uiFontScale, 1.0, accuracy: 0.001)
    }

    func testUIFontFamilyRoundTripsAndClearsOnNil() {
        PreferencesManager.shared.uiFontFamily = "Helvetica"
        XCTAssertEqual(PreferencesManager.shared.uiFontFamily, "Helvetica")

        PreferencesManager.shared.uiFontFamily = nil
        XCTAssertNil(PreferencesManager.shared.uiFontFamily)
    }

    func testEmptyStoredFamilyReadsAsDefault() {
        defaults.set("", forKey: "uiFontFamily")
        XCTAssertNil(PreferencesManager.shared.uiFontFamily)
    }

    func testUIFontScaleRoundTripsAndClamps() {
        PreferencesManager.shared.uiFontScale = 1.15
        XCTAssertEqual(PreferencesManager.shared.uiFontScale, 1.15, accuracy: 0.001)

        PreferencesManager.shared.uiFontScale = 4
        XCTAssertEqual(PreferencesManager.shared.uiFontScale, 1.5, accuracy: 0.001)

        PreferencesManager.shared.uiFontScale = 0.1
        XCTAssertEqual(PreferencesManager.shared.uiFontScale, 0.8, accuracy: 0.001)
    }

    func testClampUIFontScaleHandlesGarbage() {
        XCTAssertEqual(PreferencesManager.clampUIFontScale(0), 1.0, accuracy: 0.001)
        XCTAssertEqual(PreferencesManager.clampUIFontScale(-3), 1.0, accuracy: 0.001)
        XCTAssertEqual(PreferencesManager.clampUIFontScale(1.3), 1.3, accuracy: 0.001)
    }

    func testUIFontChangePostsNotification() {
        expectation(forNotification: .uiFontDidChange, object: nil, handler: nil)
        PreferencesManager.shared.uiFontScale = 1.15
        waitForExpectations(timeout: 1)
    }

    func testEveryOfferedScaleChoiceSurvivesClamping() {
        for choice in PreferencesManager.uiFontScaleChoices {
            XCTAssertEqual(PreferencesManager.clampUIFontScale(choice.scale), choice.scale, accuracy: 0.001,
                           "\(choice.title) is outside the allowed range")
        }
    }

    // MARK: - Theme resolution

    func testScaledMultipliesAndClamps() {
        XCTAssertEqual(Theme.scaled(12, scale: 1.5), 18, accuracy: 0.001)
        XCTAssertEqual(Theme.scaled(12, scale: 1.0), 12, accuracy: 0.001)
        // Out-of-range scales clamp rather than producing an unusable size.
        XCTAssertEqual(Theme.scaled(12, scale: 10), 18, accuracy: 0.001)
    }

    func testResolveUIFontUsesNamedFamily() {
        let font = Theme.resolveUIFont(family: "Helvetica", size: 16, weight: .regular)
        XCTAssertEqual(font.familyName, "Helvetica")
        XCTAssertEqual(font.pointSize, 16, accuracy: 0.001)
    }

    func testResolveUIFontSystemTokenUsesSystemFont() {
        let font = Theme.resolveUIFont(family: Theme.systemFamily, size: 14, weight: .semibold)
        XCTAssertEqual(font, NSFont.systemFont(ofSize: 14, weight: .semibold))
    }

    func testResolveUIFontFallsBackOnUnknownFamily() {
        let font = Theme.resolveUIFont(family: "NotARealFamily-XYZ", size: 13, weight: .regular)
        XCTAssertEqual(font.pointSize, 13, accuracy: 0.001)
    }

    func testResolveUIFontWithNilFamilyKeepsRequestedSize() {
        let font = Theme.resolveUIFont(family: nil, size: 15, weight: .semibold)
        XCTAssertEqual(font.pointSize, 15, accuracy: 0.001)
    }

    func testBodyAndMetricFollowThePreference() {
        PreferencesManager.shared.uiFontFamily = Theme.systemFamily
        PreferencesManager.shared.uiFontScale = 1.5

        XCTAssertEqual(Theme.body(12).pointSize, 18, accuracy: 0.001)
        XCTAssertEqual(Theme.heading(12).pointSize, 18, accuracy: 0.001)
        XCTAssertEqual(Theme.metric(44), 66, accuracy: 0.001)
        XCTAssertEqual(Theme.body(12).familyName, NSFont.systemFont(ofSize: 18).familyName)
        // A custom interface family takes over the serif heading face too.
        XCTAssertEqual(Theme.heading(12).familyName, NSFont.systemFont(ofSize: 18).familyName)
    }
}
