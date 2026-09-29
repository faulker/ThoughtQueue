import XCTest
import AppKit
@testable import ThoughtQueue

/// Covers the theming system: theme-file parsing, the custom Themes folder, the built-in
/// palettes, and how `Theme` tokens resolve through the active light/dark palette.
final class ThemeTests: XCTestCase {

    private var tempDir: URL!
    private let defaults = UserDefaults.standard

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ThemeTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
        defaults.removeObject(forKey: "lightThemeID")
        defaults.removeObject(forKey: "darkThemeID")
        Theme.lightPalette = .organicLight
        Theme.darkPalette = .organicDark
    }

    /// sRGB components, rounded to 8-bit, for comparing colors built different ways.
    private func rgba(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB)!
        return [c.redComponent, c.greenComponent, c.blueComponent, c.alphaComponent].map { Int(($0 * 255).rounded()) }
    }

    private func write(_ json: String, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let url = tempDir.appendingPathComponent(name)
        try json.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: - Hex parsing

    func testParseHexAcceptsSixAndEightDigits() {
        XCTAssertEqual(rgba(ThemePalette.parseHex("#ff8000")!), [255, 128, 0, 255])
        XCTAssertEqual(rgba(ThemePalette.parseHex("#ff800080")!), [255, 128, 0, 128])
    }

    func testParseHexRejectsMalformedValues() {
        for bad in ["ff8000", "#ff80", "#gg8000", "#ff8000ff00", "", "#"] {
            XCTAssertNil(ThemePalette.parseHex(bad), bad)
        }
    }

    // MARK: - Decoding

    func testDecodePartialThemeFallsBackToOrganicOfSameAppearance() throws {
        let json = ##"{"name": "Plum", "appearance": "dark", "colors": {"accent": "#aa55cc"}}"##
        let theme = try ThemePalette.decode(Data(json.utf8), id: "custom:plum")

        XCTAssertEqual(theme.id, "custom:plum")
        XCTAssertEqual(theme.name, "Plum")
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertFalse(theme.isBuiltIn)
        XCTAssertEqual(rgba(theme.accent), [0xaa, 0x55, 0xcc, 255])
        XCTAssertEqual(rgba(theme.surface), rgba(ThemePalette.organicDark.surface))
        XCTAssertEqual(theme.categoryTints.count, ThemePalette.organicDark.categoryTints.count)
    }

    func testDecodeEveryColorKeyAndCategoryTints() throws {
        let colors = ThemePalette.colorKeys.map { "\"\($0.key)\": \"#102030\"" }.joined(separator: ",")
        let json = """
        {"name": "Flat", "appearance": "light", "colors": {\(colors)},
         "categoryTints": [{"background": "#010203", "foreground": "#040506"}]}
        """
        let theme = try ThemePalette.decode(Data(json.utf8), id: "custom:flat")
        for (key, path) in ThemePalette.colorKeys {
            XCTAssertEqual(rgba(theme[keyPath: path]), [0x10, 0x20, 0x30, 255], key)
        }
        XCTAssertEqual(theme.categoryTints.count, 1)
        XCTAssertEqual(rgba(theme.categoryTints[0].foreground), [4, 5, 6, 255])
    }

    func testDecodeReportsSpecificErrors() {
        let cases: [(String, ThemePalette.DecodeError)] = [
            ("[1, 2]", .notJSONObject),
            (##"{"appearance": "dark"}"##, .missingField("name")),
            (##"{"name": "X"}"##, .missingField("appearance")),
            (##"{"name": "X", "appearance": "dim"}"##, .invalidAppearance("dim")),
            (##"{"name": "X", "appearance": "dark", "colors": {"acent": "#000000"}}"##, .unknownColorKey("acent")),
            (##"{"name": "X", "appearance": "dark", "colors": {"accent": "red"}}"##, .invalidColor(key: "accent", value: "red")),
            (##"{"name": "X", "appearance": "dark", "categoryTints": []}"##, .invalidCategoryTints),
            (##"{"name": "X", "appearance": "dark", "categoryTints": [{"background": "#000000"}]}"##, .invalidCategoryTints),
        ]
        for (json, expected) in cases {
            XCTAssertThrowsError(try ThemePalette.decode(Data(json.utf8), id: "x"), json) { error in
                XCTAssertEqual(error as? ThemePalette.DecodeError, expected, json)
            }
        }
    }

    // MARK: - Built-ins

    func testBuiltInsIncludeTwoLightAndTwoDarkThemesWithUniqueIDs() {
        let builtIns = ThemePalette.builtIns
        XCTAssertEqual(builtIns.filter { $0.appearance == .light }.map(\.id), ["organic-light", "porcelain"])
        XCTAssertEqual(builtIns.filter { $0.appearance == .dark }.map(\.id), ["organic-dark", "midnight"])
        XCTAssertEqual(Set(builtIns.map(\.id)).count, builtIns.count)
        XCTAssertTrue(builtIns.allSatisfy { $0.isBuiltIn && !$0.categoryTints.isEmpty })
    }

    func testDocumentedExampleThemeDecodes() throws {
        // docs/themes.md ships a complete example; keep it valid as tokens change.
        let docs = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("docs/themes.md")
        let text = try String(contentsOf: docs, encoding: .utf8)
        let start = try XCTUnwrap(text.range(of: "```json\n"))
        let end = try XCTUnwrap(text.range(of: "\n```", range: start.upperBound..<text.endIndex))
        let json = String(text[start.upperBound..<end.lowerBound])
        let theme = try ThemePalette.decode(Data(json.utf8), id: "custom:example")
        XCTAssertEqual(theme.appearance, .dark)
        for (key, _) in ThemePalette.colorKeys {
            XCTAssertTrue(json.contains("\"\(key)\""), "example is missing \(key)")
        }
    }

    // MARK: - Themes folder

    func testLoadCustomThemesCollectsValidFilesAndReportsBadOnes() throws {
        _ = try write(##"{"name": "Zed", "appearance": "light"}"##, named: "zed.json")
        _ = try write(##"{"name": "Alpha", "appearance": "dark"}"##, named: "alpha.json")
        _ = try write(##"{"name": "Broken"}"##, named: "broken.json")
        _ = try write("not a theme", named: "notes.txt")

        let (themes, failures) = ThemeLibrary.loadCustomThemes(in: tempDir)
        XCTAssertEqual(themes.map(\.name), ["Alpha", "Zed"])
        XCTAssertEqual(themes.map(\.id), ["custom:alpha", "custom:zed"])
        XCTAssertEqual(failures, [ThemeLibrary.LoadFailure(fileName: "broken.json", reason: "missing \"appearance\"")])
    }

    func testMissingFolderMeansNoCustomThemes() {
        let (themes, failures) = ThemeLibrary.loadCustomThemes(in: tempDir.appendingPathComponent("nope"))
        XCTAssertTrue(themes.isEmpty)
        XCTAssertTrue(failures.isEmpty)
    }

    func testImportCopiesIntoFolderAndReloads() throws {
        let sourceDir = tempDir.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        let source = sourceDir.appendingPathComponent("ocean.json")
        try Data(##"{"name": "Ocean", "appearance": "dark"}"##.utf8).write(to: source)

        let library = ThemeLibrary(folderURL: tempDir.appendingPathComponent("Themes"))
        let theme = try library.importTheme(from: source)

        XCTAssertEqual(theme.id, "custom:ocean")
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.folderURL.appendingPathComponent("ocean.json").path))
        XCTAssertEqual(library.themes(for: .dark).map(\.id), ["organic-dark", "midnight", "custom:ocean"])
    }

    func testImportRejectsInvalidFileWithoutCopying() throws {
        let source = try write(##"{"name": "Bad", "appearance": "sepia"}"##, named: "bad.json")
        let library = ThemeLibrary(folderURL: tempDir.appendingPathComponent("Themes"))

        XCTAssertThrowsError(try library.importTheme(from: source))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library.folderURL.path))
    }

    func testResolveFallsBackToOrganicForUnknownOrWrongAppearanceIDs() {
        let library = ThemeLibrary(folderURL: tempDir)
        XCTAssertEqual(library.resolve(id: "midnight", appearance: .dark).id, "midnight")
        XCTAssertEqual(library.resolve(id: "custom:gone", appearance: .dark).id, "organic-dark")
        XCTAssertEqual(library.resolve(id: "midnight", appearance: .light).id, "organic-light")
        XCTAssertEqual(library.resolve(id: nil, appearance: .light).id, "organic-light")
    }

    // MARK: - Applying

    func testThemeTokensResolveThroughActivePaletteForEachAppearance() {
        Theme.lightPalette = .porcelain
        Theme.darkPalette = .midnight
        let light = NSAppearance(named: .aqua)!
        let dark = NSAppearance(named: .darkAqua)!

        var resolved: NSColor!
        light.performAsCurrentDrawingAppearance { resolved = Theme.accent.usingColorSpace(.sRGB) }
        XCTAssertEqual(rgba(resolved), rgba(ThemePalette.porcelain.accent))
        dark.performAsCurrentDrawingAppearance { resolved = Theme.surface.usingColorSpace(.sRGB) }
        XCTAssertEqual(rgba(resolved), rgba(ThemePalette.midnight.surface))
        dark.performAsCurrentDrawingAppearance {
            resolved = Theme.categoryTint(for: "Work").foreground.usingColorSpace(.sRGB)
        }
        XCTAssertTrue(ThemePalette.midnight.categoryTints.map { rgba($0.foreground) }.contains(rgba(resolved)))
    }

    func testSelectingThemeIDsAppliesPalettes() {
        PreferencesManager.shared.lightThemeID = "porcelain"
        PreferencesManager.shared.darkThemeID = "midnight"
        XCTAssertEqual(Theme.lightPalette.id, "porcelain")
        XCTAssertEqual(Theme.darkPalette.id, "midnight")

        PreferencesManager.shared.lightThemeID = nil
        XCTAssertEqual(Theme.lightPalette.id, "organic-light")
    }

    func testThemeSelectionIsSyncable() {
        XCTAssertTrue(PreferencesManager.syncableKeys.contains("lightThemeID"))
        XCTAssertTrue(PreferencesManager.syncableKeys.contains("darkThemeID"))
    }
}
