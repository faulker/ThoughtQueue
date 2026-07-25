import XCTest
@testable import ThoughtQueue

/// Covers the pure, filesystem-free surface of SettingsSync: which keys travel, plist
/// round-tripping, and the whitelist guard that keeps device-local values from being imported.
final class SettingsSyncTests: XCTestCase {

    /// An isolated defaults suite so tests never touch the real app preferences.
    private func makeDefaults(_ name: String = #function) -> UserDefaults {
        let suite = "SettingsSyncTests.\(name)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testSyncableValuesIncludesWhitelistedKeysOnly() {
        let d = makeDefaults()
        d.set("editRaw", forKey: "clickBehavior")
        d.set(18.0, forKey: "editorFontSize")
        // Device-local keys that must never be part of a sync snapshot.
        d.set("/Users/someone/Notes", forKey: "storeFolderPath")
        d.set("/Users/someone/Notes/wd.md", forKey: "workingDocumentPath")

        let values = SettingsSync.syncableValues(from: d)

        XCTAssertEqual(values["clickBehavior"] as? String, "editRaw")
        XCTAssertEqual(values["editorFontSize"] as? Double, 18.0)
        XCTAssertNil(values["storeFolderPath"], "store path must never be synced")
        XCTAssertNil(values["workingDocumentPath"], "working document path must never be synced")
        XCTAssertNil(values["syncSettingsEnabled"], "the sync flag itself must never be synced")
    }

    func testSerializeRoundTripsIncludingDataValues() {
        // openWithActions is stored as JSON Data; the plist encoding must survive it.
        let blob = Data([0x00, 0x01, 0x02, 0xFF])
        let values: [String: Any] = [
            "clickBehavior": "renderMarkdown",
            "toastTimeout": 12.5,
            "quickCaptureKeyCode": 11,
            "autoIntelEnabled": false,
            "openWithActions": blob,
        ]

        let data = SettingsSync.serialize(values)
        XCTAssertNotNil(data)
        let decoded = SettingsSync.deserialize(data!)
        XCTAssertNotNil(decoded)
        XCTAssertEqual(decoded?["clickBehavior"] as? String, "renderMarkdown")
        XCTAssertEqual(decoded?["toastTimeout"] as? Double, 12.5)
        XCTAssertEqual(decoded?["quickCaptureKeyCode"] as? Int, 11)
        XCTAssertEqual(decoded?["autoIntelEnabled"] as? Bool, false)
        XCTAssertEqual(decoded?["openWithActions"] as? Data, blob)
    }

    func testApplyIgnoresNonWhitelistedKeys() {
        let d = makeDefaults()
        let malicious: [String: Any] = [
            "noteAlwaysOnTop": true,               // whitelisted → applied
            "storeFolderPath": "/evil/path",       // not whitelisted → ignored
            "syncSettingsEnabled": false,          // not whitelisted → ignored
        ]

        SettingsSync.apply(malicious, to: d)

        XCTAssertTrue(d.bool(forKey: "noteAlwaysOnTop"))
        XCTAssertNil(d.string(forKey: "storeFolderPath"), "import must never overwrite the store path")
        XCTAssertNil(d.object(forKey: "syncSettingsEnabled"), "import must never flip the sync flag")
    }

    func testSyncableValuesSnapshotAppliesBackIdentically() {
        let source = makeDefaults("source")
        source.set("singleClick", forKey: "noteEditMode")
        source.set(460.0, forKey: "noteWindowWidth")
        source.set(true, forKey: "autoIntelEnabled")

        let snapshot = SettingsSync.syncableValues(from: source)
        let dest = makeDefaults("dest")
        SettingsSync.apply(snapshot, to: dest)

        XCTAssertEqual(dest.string(forKey: "noteEditMode"), "singleClick")
        XCTAssertEqual(dest.double(forKey: "noteWindowWidth"), 460.0)
        XCTAssertTrue(dest.bool(forKey: "autoIntelEnabled"))
    }

    func testChangedKeysIgnoresEqualSnapshots() {
        // A re-import of identical settings (e.g. on every app activation) must report no
        // changes, so no live-update notification fires to clobber per-window pin overrides.
        let snapshot: [String: Any] = [
            "noteAlwaysOnTop": true,
            "editorFontSize": 14.0,
            "noteEditMode": "renderMarkdown",
        ]
        XCTAssertTrue(SettingsSync.changedKeys(before: snapshot, after: snapshot).isEmpty)
    }

    func testChangedKeysDetectsAlwaysOnTopFlip() {
        let before: [String: Any] = ["noteAlwaysOnTop": true, "editorFontSize": 14.0]
        let after: [String: Any] = ["noteAlwaysOnTop": false, "editorFontSize": 14.0]
        let changed = SettingsSync.changedKeys(before: before, after: after)
        XCTAssertTrue(changed.contains("noteAlwaysOnTop"))
        XCTAssertFalse(changed.contains("editorFontSize"))
    }

    func testChangedKeysTreatsAppearedKeyAsChanged() {
        let before: [String: Any] = [:]
        let after: [String: Any] = ["editorFontName": "Menlo"]
        XCTAssertTrue(SettingsSync.changedKeys(before: before, after: after).contains("editorFontName"))
    }

    func testChangedKeysIgnoresNonSyncableKeys() {
        // Keys outside the whitelist never count, even if they differ.
        let before: [String: Any] = ["storeFolderPath": "/a"]
        let after: [String: Any] = ["storeFolderPath": "/b"]
        XCTAssertTrue(SettingsSync.changedKeys(before: before, after: after).isEmpty)
    }

    func testSyncSettingsEnabledDefaultsToTrue() {
        let saved = UserDefaults.standard.object(forKey: "syncSettingsEnabled")
        defer { UserDefaults.standard.set(saved, forKey: "syncSettingsEnabled") }

        UserDefaults.standard.removeObject(forKey: "syncSettingsEnabled")
        XCTAssertTrue(PreferencesManager.shared.syncSettingsEnabled, "sync should default to on")
    }
}
