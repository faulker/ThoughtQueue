import XCTest
@testable import ThoughtQueue

/// Covers the pure decision-making in `UpdateService`: parsing GitHub's redirect target,
/// deciding whether a release is actually newer, and verifying a download against the
/// release's published checksums. The network call and the bundle swap are not exercised here.
final class UpdateServiceTests: XCTestCase {

    // MARK: - Version parsing

    func testParseVersionFromTagURL() {
        let url = URL(string: "https://github.com/faulker/ThoughtQueue/releases/tag/v1.2.3")!
        XCTAssertEqual(UpdateService.parseVersion(fromTagURL: url), "1.2.3")
    }

    func testParseVersionAcceptsBareTagWithoutVPrefix() {
        let url = URL(string: "https://github.com/faulker/ThoughtQueue/releases/tag/1.2.3")!
        XCTAssertEqual(UpdateService.parseVersion(fromTagURL: url), "1.2.3")
    }

    func testParseVersionRejectsNonVersionURLs() {
        // GitHub redirects here when a repo has no releases at all.
        let releasesIndex = URL(string: "https://github.com/faulker/ThoughtQueue/releases")!
        XCTAssertNil(UpdateService.parseVersion(fromTagURL: releasesIndex))

        let named = URL(string: "https://github.com/faulker/ThoughtQueue/releases/tag/nightly")!
        XCTAssertNil(UpdateService.parseVersion(fromTagURL: named))
    }

    // MARK: - Version comparison

    func testIsNewerComparesNumericallyNotLexically() {
        XCTAssertTrue(UpdateService.isNewer("1.10.0", than: "1.9.0"))
        XCTAssertFalse(UpdateService.isNewer("1.9.0", than: "1.10.0"))
    }

    func testIsNewerIsFalseForEqualVersions() {
        XCTAssertFalse(UpdateService.isNewer("1.0.0", than: "1.0.0"))
    }

    func testIsNewerIsFalseForOlderVersions() {
        XCTAssertFalse(UpdateService.isNewer("0.9.9", than: "1.0.0"))
    }

    func testCompareTreatsMissingComponentsAsZero() {
        XCTAssertEqual(UpdateService.compare("2.0", "2.0.0"), .orderedSame)
        XCTAssertEqual(UpdateService.compare("2", "1.9.9"), .orderedDescending)
    }

    func testCompareStripsPrereleaseAndBuildSuffixes() {
        XCTAssertEqual(UpdateService.compare("1.2.3-beta.1", "1.2.3"), .orderedSame)
        XCTAssertEqual(UpdateService.compare("1.2.3+build9", "1.2.3"), .orderedSame)
        XCTAssertTrue(UpdateService.isNewer("1.3.0-rc1", than: "1.2.3"))
    }

    // MARK: - Checksums

    /// The exact format the release workflow produces (shasum run from inside dist/).
    private let checksums = """
    d975f870c534eeefb57710bfee3345a6fd8d87b25b6f8966d9d6d7d0f92f01ec  ./ThoughtQueue-1.0.0.dmg
    51be17b7a01e1e7abb1dc68faeafb466185902354e77b7216037a9cb8c9a1f0b  ./ThoughtQueue-1.0.0.zip
    """

    func testExpectedSHA256FindsAssetIgnoringDotSlashPrefix() {
        XCTAssertEqual(
            UpdateService.expectedSHA256(for: "ThoughtQueue-1.0.0.zip", in: checksums),
            "51be17b7a01e1e7abb1dc68faeafb466185902354e77b7216037a9cb8c9a1f0b"
        )
        XCTAssertEqual(
            UpdateService.expectedSHA256(for: "ThoughtQueue-1.0.0.dmg", in: checksums),
            "d975f870c534eeefb57710bfee3345a6fd8d87b25b6f8966d9d6d7d0f92f01ec"
        )
    }

    func testExpectedSHA256ReturnsNilForUnlistedAsset() {
        XCTAssertNil(UpdateService.expectedSHA256(for: "ThoughtQueue-9.9.9.zip", in: checksums))
        XCTAssertNil(UpdateService.expectedSHA256(for: "ThoughtQueue-1.0.0.zip", in: ""))
    }

    func testExpectedSHA256DoesNotPartialMatchFilenames() {
        // "Queue-1.0.0.zip" is a suffix of the listed name but is not the same asset.
        XCTAssertNil(UpdateService.expectedSHA256(for: "Queue-1.0.0.zip", in: checksums))
    }

    func testExpectedSHA256HandlesBinaryMarkerAndSpacedNames() {
        let block = """
        aaaa1111  *ThoughtQueue-1.0.0.zip
        bbbb2222  ./My Build 1.0.0.zip
        """
        XCTAssertEqual(UpdateService.expectedSHA256(for: "ThoughtQueue-1.0.0.zip", in: block), "aaaa1111")
        XCTAssertEqual(UpdateService.expectedSHA256(for: "My Build 1.0.0.zip", in: block), "bbbb2222")
    }

    func testSHA256MatchesKnownVector() {
        let data = "abc".data(using: .utf8)!
        XCTAssertEqual(
            UpdateService.sha256Hex(of: data),
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    // MARK: - URLs

    func testReleaseURLConstruction() {
        XCTAssertEqual(
            UpdateService.latestReleaseURL.absoluteString,
            "https://github.com/faulker/ThoughtQueue/releases/latest"
        )
        XCTAssertEqual(
            UpdateService.assetURL(version: "1.2.3", filename: "ThoughtQueue-1.2.3.zip").absoluteString,
            "https://github.com/faulker/ThoughtQueue/releases/download/v1.2.3/ThoughtQueue-1.2.3.zip"
        )
        XCTAssertEqual(
            UpdateService.releasePageURL(version: "1.2.3").absoluteString,
            "https://github.com/faulker/ThoughtQueue/releases/tag/v1.2.3"
        )
    }

    func testReleaseDerivesItsOwnAssetURLs() {
        let release = UpdateService.Release(version: "2.1.0")
        XCTAssertEqual(release.tag, "v2.1.0")
        XCTAssertTrue(release.zipURL.absoluteString.hasSuffix("/v2.1.0/ThoughtQueue-2.1.0.zip"))
        XCTAssertTrue(release.checksumsURL.absoluteString.hasSuffix("/v2.1.0/checksums-sha256.txt"))
    }

    // MARK: - Interval choices

    func testIntervalChoicesCoverTheDefaultAndAreOrdered() {
        let hours = UpdateService.intervalChoices.map(\.hours)
        XCTAssertEqual(hours, [1, 6, 24, 168])
        XCTAssertTrue(hours.contains(PreferencesManager.defaultUpdateCheckIntervalHours))
        // The popup stores a selection by index, so titles and hours must stay 1:1.
        XCTAssertEqual(UpdateService.intervalChoices.count, Set(hours).count)
    }

    // MARK: - Swap helper script

    func testSwapScriptWaitsForExitAndRollsBack() {
        let script = UpdateService.swapScript(
            pid: 4242,
            installed: "/Applications/ThoughtQueue.app",
            staged: "/tmp/staged/ThoughtQueue.app",
            workDir: "/tmp/staged"
        )
        XCTAssertTrue(script.contains("PID=4242"))
        // Must wait for the old process before touching the installed bundle.
        XCTAssertTrue(script.contains("kill -0 \"$PID\""))
        // Must restore the backup if the move-in fails.
        XCTAssertTrue(script.contains("mv \"$BACKUP\" \"$INSTALLED\""))
        XCTAssertTrue(script.contains("open -n \"$INSTALLED\""))
    }

    func testSwapScriptQuotesPathsContainingApostrophes() {
        let script = UpdateService.swapScript(
            pid: 1,
            installed: "/Users/o'brien/Applications/ThoughtQueue.app",
            staged: "/tmp/s/ThoughtQueue.app",
            workDir: "/tmp/s"
        )
        // The apostrophe must be escaped out of the single-quoted string, not left to close it.
        XCTAssertTrue(script.contains("'/Users/o'\\''brien/Applications/ThoughtQueue.app'"))
    }

    func testShellQuoteEscapesEmbeddedQuotes() {
        XCTAssertEqual(UpdateService.shellQuote("/tmp/plain"), "'/tmp/plain'")
        XCTAssertEqual(UpdateService.shellQuote("a'b"), "'a'\\''b'")
    }

    func testCurrentVersionIsVersionShaped() {
        let version = UpdateService.currentVersion()
        XCTAssertFalse(version.isEmpty)
        XCTAssertNotNil(Int(version.split(separator: ".").first.map(String.init) ?? "x"))
    }

    func testLocalDevelopmentBuildDetectsDerivedDataAndBuildProducts() {
        let derived = URL(fileURLWithPath:
            "/Users/me/Library/Developer/Xcode/DerivedData/ThoughtQueue-abc/Build/Products/Debug/ThoughtQueue.app")
        XCTAssertTrue(UpdateService.isLocalDevelopmentBuild(bundleURL: derived))

        let buildScript = URL(fileURLWithPath:
            "/Users/me/Dev/ThoughtQueue/build/Build/Products/Release/ThoughtQueue.app")
        XCTAssertTrue(UpdateService.isLocalDevelopmentBuild(bundleURL: buildScript))
    }

    func testLocalDevelopmentBuildRejectsInstalledAndDownloadedPaths() {
        let applications = URL(fileURLWithPath: "/Applications/ThoughtQueue.app")
        XCTAssertFalse(UpdateService.isLocalDevelopmentBuild(bundleURL: applications))

        let homeApps = URL(fileURLWithPath: "/Users/me/Applications/ThoughtQueue.app")
        XCTAssertFalse(UpdateService.isLocalDevelopmentBuild(bundleURL: homeApps))

        let downloads = URL(fileURLWithPath: "/Users/me/Downloads/ThoughtQueue.app")
        XCTAssertFalse(UpdateService.isLocalDevelopmentBuild(bundleURL: downloads))
    }
}
