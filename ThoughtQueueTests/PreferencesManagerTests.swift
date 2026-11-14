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

    func testAutoUpdateCheckDefaultsToEnabled() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "autoUpdateCheckEnabled")
        defer { defaults.set(saved, forKey: "autoUpdateCheckEnabled") }
        defaults.removeObject(forKey: "autoUpdateCheckEnabled")

        XCTAssertTrue(PreferencesManager.shared.autoUpdateCheckEnabled)
    }

    func testAutoUpdateCheckRoundTripsAndPostsNotification() {
        let saved = PreferencesManager.shared.autoUpdateCheckEnabled
        defer { PreferencesManager.shared.autoUpdateCheckEnabled = saved }

        let expectation = expectation(forNotification: .updateCheckSettingsDidChange, object: nil)
        PreferencesManager.shared.autoUpdateCheckEnabled = false
        XCTAssertFalse(PreferencesManager.shared.autoUpdateCheckEnabled)
        wait(for: [expectation], timeout: 1)
    }

    func testUpdateCheckIntervalDefaultsWhenUnset() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "updateCheckIntervalHours")
        defer { defaults.set(saved, forKey: "updateCheckIntervalHours") }
        defaults.removeObject(forKey: "updateCheckIntervalHours")

        XCTAssertEqual(PreferencesManager.shared.updateCheckIntervalHours,
                       PreferencesManager.defaultUpdateCheckIntervalHours)
    }

    func testUpdateCheckIntervalRoundTripsAndClamps() {
        let saved = PreferencesManager.shared.updateCheckIntervalHours
        defer { PreferencesManager.shared.updateCheckIntervalHours = saved }

        PreferencesManager.shared.updateCheckIntervalHours = 6
        XCTAssertEqual(PreferencesManager.shared.updateCheckIntervalHours, 6)

        // A hand-edited or synced value can't produce a runaway or absurdly rare timer.
        PreferencesManager.shared.updateCheckIntervalHours = 10_000
        XCTAssertEqual(PreferencesManager.shared.updateCheckIntervalHours, 168)
        PreferencesManager.shared.updateCheckIntervalHours = 0
        XCTAssertEqual(PreferencesManager.shared.updateCheckIntervalHours, 1)
    }

    func testLastUpdateCheckAtRoundTripsAndStartsNil() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "lastUpdateCheckAt")
        defer { defaults.set(saved, forKey: "lastUpdateCheckAt") }
        defaults.removeObject(forKey: "lastUpdateCheckAt")

        XCTAssertNil(PreferencesManager.shared.lastUpdateCheckAt)

        let now = Date()
        PreferencesManager.shared.lastUpdateCheckAt = now
        XCTAssertEqual(PreferencesManager.shared.lastUpdateCheckAt?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testUpdateCheckKeysAreSyncableButLastCheckIsNot() {
        XCTAssertTrue(PreferencesManager.syncableKeys.contains("autoUpdateCheckEnabled"))
        XCTAssertTrue(PreferencesManager.syncableKeys.contains("updateCheckIntervalHours"))
        // Device-local: another Mac's check time says nothing about this one.
        XCTAssertFalse(PreferencesManager.syncableKeys.contains("lastUpdateCheckAt"))
    }

    func testThemeModeDefaultsToSystemAndRoundTrips() {
        let defaults = UserDefaults.standard
        let saved = defaults.object(forKey: "themeMode")
        defer { defaults.set(saved, forKey: "themeMode") }
        defaults.removeObject(forKey: "themeMode")

        XCTAssertEqual(PreferencesManager.shared.themeMode, .system)

        PreferencesManager.shared.themeMode = .dark
        XCTAssertEqual(PreferencesManager.shared.themeMode, .dark)
        PreferencesManager.shared.themeMode = .light
        XCTAssertEqual(PreferencesManager.shared.themeMode, .light)
    }

    func testThemeModeIsSyncable() {
        XCTAssertTrue(PreferencesManager.syncableKeys.contains("themeMode"))
    }

    // MARK: - Storage mode

    /// Each storage mode resolves to the right store root.
    func testEffectiveStoreRootPerMode() {
        let folder = URL(fileURLWithPath: "/tmp/tq-notes", isDirectory: true)
        let cache = URL(fileURLWithPath: "/tmp/tq-cache", isDirectory: true)
        XCTAssertEqual(PreferencesManager.effectiveStoreRoot(mode: .local, storeURL: folder, cacheURL: cache), folder)
        XCTAssertEqual(PreferencesManager.effectiveStoreRoot(mode: .both, storeURL: folder, cacheURL: cache), folder)
        XCTAssertEqual(PreferencesManager.effectiveStoreRoot(mode: .s3, storeURL: folder, cacheURL: cache), cache)
        XCTAssertEqual(PreferencesManager.effectiveStoreRoot(mode: .s3, storeURL: nil, cacheURL: cache), cache)
        XCTAssertNil(PreferencesManager.effectiveStoreRoot(mode: .local, storeURL: nil, cacheURL: cache))
        XCTAssertNil(PreferencesManager.effectiveStoreRoot(mode: .both, storeURL: nil, cacheURL: cache))
    }

    /// The S3 cache lives in Application Support, outside any user folder.
    func testS3CacheURLIsInApplicationSupport() {
        let path = PreferencesManager.s3CacheURL.path
        XCTAssertTrue(path.hasSuffix("Application Support/ThoughtQueue/S3Cache"), path)
    }

    /// Valid fields build a config; a missing bucket, key ID, or bad endpoint does not.
    func testMakeS3Config() throws {
        let config = try XCTUnwrap(PreferencesManager.makeS3Config(
            endpoint: " http://localhost:9000 ", region: "", bucket: "notes", prefix: "tq/",
            usePathStyle: true, accessKeyID: "AKID"))
        XCTAssertEqual(config.endpoint.absoluteString, "http://localhost:9000")
        XCTAssertEqual(config.region, "us-east-1")
        XCTAssertEqual(config.normalizedPrefix, "tq/")
        XCTAssertNil(PreferencesManager.makeS3Config(endpoint: "http://h", region: "", bucket: "", prefix: "",
                                                     usePathStyle: true, accessKeyID: "AKID"))
        XCTAssertNil(PreferencesManager.makeS3Config(endpoint: "http://h", region: "", bucket: "b", prefix: "",
                                                     usePathStyle: true, accessKeyID: ""))
        XCTAssertNil(PreferencesManager.makeS3Config(endpoint: "not a url", region: "", bucket: "b", prefix: "",
                                                     usePathStyle: true, accessKeyID: "AKID"))
    }

    /// S3 sync settings are device-local and never mirrored into the store folder.
    func testSyncSettingsAreNotSyncable() {
        for key in ["storageMode", "s3Endpoint", "s3Bucket", "s3AccessKeyID", "syncOnChange", "syncInterval"] {
            XCTAssertFalse(PreferencesManager.syncableKeys.contains(key), key)
        }
    }
}
