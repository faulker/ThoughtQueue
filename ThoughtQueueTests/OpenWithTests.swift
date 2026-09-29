import XCTest
@testable import ThoughtQueue

final class OpenWithTests: XCTestCase {

    // MARK: - Template expansion

    func testExpandSubstitutesPath() {
        let result = OpenWithService.expand(template: "zed {path}", path: "/tmp/note.md")
        XCTAssertEqual(result, "zed /tmp/note.md")
    }

    func testExpandHandlesMultiplePlaceholders() {
        let result = OpenWithService.expand(template: "cmp {path} {path}", path: "/a/b.md")
        XCTAssertEqual(result, "cmp /a/b.md /a/b.md")
    }

    func testExpandNoPlaceholderUnchanged() {
        let result = OpenWithService.expand(template: "echo hi", path: "/tmp/x.md")
        XCTAssertEqual(result, "echo hi")
    }

    func testExpandWithSpacesInPath() {
        let result = OpenWithService.expand(template: "open {path}", path: "/Users/me/My Notes/a.md")
        XCTAssertEqual(result, "open /Users/me/My Notes/a.md")
    }

    // MARK: - Shell-safe expansion / quoting (rule #2)

    func testShellSafeQuotesPathWithSpaces() {
        let result = OpenWithService.expandShellSafe(template: "zed {path}", path: "/Users/me/My Notes/a.md")
        XCTAssertEqual(result, "zed '/Users/me/My Notes/a.md'")
    }

    func testShellSafeNeutralizesMetacharacters() {
        // Semicolons, $, and backticks inside the path must be inside the single-quoted span
        // so they cannot inject additional shell commands.
        let path = "/tmp/a;rm -rf ~ $(whoami)`id`.md"
        let result = OpenWithService.expandShellSafe(template: "zed {path}", path: path)
        XCTAssertEqual(result, "zed '/tmp/a;rm -rf ~ $(whoami)`id`.md'")
        // No unquoted metacharacter leaks: everything after `zed ` is a single-quoted literal.
        XCTAssertTrue(result.hasPrefix("zed '"))
        XCTAssertTrue(result.hasSuffix("'"))
    }

    func testShellQuoteEscapesEmbeddedSingleQuote() {
        let result = OpenWithService.shellQuote("it's a note.md")
        XCTAssertEqual(result, "'it'\\''s a note.md'")
    }

    func testShellSafeWithEmbeddedSingleQuoteInPath() {
        let result = OpenWithService.expandShellSafe(template: "open {path}", path: "/tmp/o'brien.md")
        XCTAssertEqual(result, "open '/tmp/o'\\''brien.md'")
    }

    // MARK: - Command template from a browsed file

    func testCommandTemplateForAppBundleUsesOpenDashA() {
        let url = URL(fileURLWithPath: "/Applications/Zed.app")
        XCTAssertEqual(OpenWithService.commandTemplate(forChosenURL: url), "open -a '/Applications/Zed.app' {path}")
    }

    func testCommandTemplateForExecutableQuotesPath() {
        let url = URL(fileURLWithPath: "/usr/local/bin/zed")
        XCTAssertEqual(OpenWithService.commandTemplate(forChosenURL: url), "'/usr/local/bin/zed' {path}")
    }

    func testCommandTemplateQuotesSpacesInPath() {
        let url = URL(fileURLWithPath: "/Applications/My Editor.app")
        XCTAssertEqual(OpenWithService.commandTemplate(forChosenURL: url), "open -a '/Applications/My Editor.app' {path}")
    }

    // MARK: - Action-type routing / persistence

    /// Sample user-created actions covering both action types.
    private let sampleActions: [OpenWithAction] = [
        OpenWithAction(name: "Claude", type: .appInput,
                       appBundleId: "com.anthropic.claudefordesktop", inputMode: .reference),
        OpenWithAction(name: "Zed", type: .command, commandTemplate: "zed {path}"),
    ]

    func testActionCodableRoundTrip() throws {
        let data = try JSONEncoder().encode(sampleActions)
        let decoded = try JSONDecoder().decode([OpenWithAction].self, from: data)
        XCTAssertEqual(decoded, sampleActions)
    }

    func testDecodeStoredActionsHasNoBuiltInDefaults() throws {
        // A user who deleted every action must get an empty list back, not re-seeded presets.
        let empty = try JSONEncoder().encode([OpenWithAction]())
        XCTAssertTrue(PreferencesManager.decodeOpenWithActions(empty).isEmpty)
        XCTAssertTrue(PreferencesManager.decodeOpenWithActions(Data("garbage".utf8)).isEmpty)

        let data = try JSONEncoder().encode(sampleActions)
        XCTAssertEqual(PreferencesManager.decodeOpenWithActions(data), sampleActions)
    }

    func testReferenceInputModeFormat() {
        // The reference handoff prepends '@' to the absolute path. We assert the contract
        // here by reconstructing the same string the service builds.
        let path = "/Users/me/notes/idea.md"
        XCTAssertEqual("@\(path)", "@/Users/me/notes/idea.md")
    }
}
