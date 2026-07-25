import Cocoa
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "SettingsSync")

extension Notification.Name {
    /// Posted after syncable settings are imported from the store folder (e.g. a change made on
    /// another device arrived via file sync), so open UI can refresh from UserDefaults.
    static let syncedSettingsDidImport = Notification.Name("syncedSettingsDidImport")
}

/// Mirrors the whitelisted, non-device-specific settings into a plist inside the store folder
/// (`.thoughtqueue/settings.plist`). Because the store folder is user-chosen and typically lives
/// in iCloud/Dropbox/etc., that file rides the same sync and lands on the user's other devices.
///
/// Enabled by default; when disabled, settings stay in local UserDefaults only. The mirror is a
/// one-file plist, not a merge engine: last write wins, which is the right model for a single
/// user's own devices. Only `PreferencesManager.syncableKeys` are ever read or written, so the
/// store path and other device-local values can never travel between machines.
final class SettingsSync {
    static let shared = SettingsSync()

    private let defaults = UserDefaults.standard
    private let fm = FileManager.default
    /// True while applying an imported file, so the resulting UserDefaults changes don't bounce
    /// straight back out as an export (which would cause a write/sync loop).
    private var isImporting = false
    private var exportDebounce: DispatchWorkItem?
    private var observing = false

    private init() {}

    /// The settings file inside the current store folder, or nil when no store root is set.
    /// Lives in a hidden `.thoughtqueue` subfolder so it never shows up as a note or category.
    var settingsFileURL: URL? {
        guard let root = NoteStore.shared.rootURL else { return nil }
        return root.appendingPathComponent(".thoughtqueue", isDirectory: true)
            .appendingPathComponent("settings.plist")
    }

    // MARK: - Lifecycle

    /// Import any existing synced settings, then begin mirroring local changes back out.
    /// No-op (and tears down any observers) when sync is disabled. Safe to call repeatedly, e.g.
    /// after the store folder changes.
    func start() {
        guard PreferencesManager.shared.syncSettingsEnabled else { stop(); return }
        importFromStore()
        // Seed the file so a fresh store folder has something for other devices to pull.
        exportToStore()
        beginObserving()
    }

    /// Stop mirroring. Leaves any existing settings file in place.
    func stop() {
        endObserving()
        exportDebounce?.cancel()
        exportDebounce = nil
    }

    /// React to the sync toggle flipping in Preferences. `start()` already branches on the flag.
    func syncEnabledChanged() {
        start()
    }

    private func beginObserving() {
        guard !observing else { return }
        observing = true
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(defaultsChanged),
                       name: UserDefaults.didChangeNotification, object: nil)
        nc.addObserver(self, selector: #selector(appBecameActive),
                       name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    private func endObserving() {
        guard observing else { return }
        observing = false
        let nc = NotificationCenter.default
        nc.removeObserver(self, name: UserDefaults.didChangeNotification, object: nil)
        nc.removeObserver(self, name: NSApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func defaultsChanged() {
        guard !isImporting else { return }
        scheduleExport()
    }

    @objc private func appBecameActive() {
        // Another device may have written the file while we were in the background.
        importFromStore()
    }

    // MARK: - Export

    /// Coalesce bursts of setting changes into a single write.
    private func scheduleExport() {
        exportDebounce?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.exportToStore() }
        exportDebounce = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: item)
    }

    /// Write the current syncable settings to the store folder.
    func exportToStore() {
        guard PreferencesManager.shared.syncSettingsEnabled, let url = settingsFileURL else { return }
        let values = Self.syncableValues(from: defaults)
        guard let data = Self.serialize(values) else { return }
        do {
            try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Tell the folder watcher to ignore the resulting FSEvent so it doesn't reload the UI.
            NoteStore.shared.registerSelfWrite(url)
            try data.write(to: url, options: .atomic)
        } catch {
            log.error("settings export failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Import

    /// Load synced settings from the store folder into UserDefaults, if the file exists.
    /// Re-posts the live-update notifications for settings that drive open windows, since setting
    /// UserDefaults directly bypasses the PreferencesManager setters that normally fire them.
    ///
    /// This runs on every app activation (not just genuine syncs), so the live-update
    /// notifications are only posted when the imported value actually differs from what's already
    /// stored. `.noteAlwaysOnTopDidChange` in particular resets each note window's per-session pin
    /// override, so firing it spuriously on every refocus would clobber a user's manual pin toggle.
    func importFromStore() {
        guard PreferencesManager.shared.syncSettingsEnabled,
              let url = settingsFileURL,
              let data = try? Data(contentsOf: url),
              let values = Self.deserialize(data) else { return }

        let before = Self.syncableValues(from: defaults)
        isImporting = true
        Self.apply(values, to: defaults)
        isImporting = false
        let after = Self.syncableValues(from: defaults)
        let changed = Self.changedKeys(before: before, after: after)

        let nc = NotificationCenter.default
        // Only the keys that actually changed get a live-update post. These run on every app
        // activation, and `.noteAlwaysOnTopDidChange` resets each note window's per-session pin
        // override, so posting it spuriously would clobber a user's manual pin toggle on refocus.
        if changed.contains(SyncKeys.editorFontName) || changed.contains(SyncKeys.editorFontSize) {
            nc.post(name: .editorFontDidChange, object: nil)
        }
        if changed.contains(SyncKeys.noteAlwaysOnTop) {
            nc.post(name: .noteAlwaysOnTopDidChange, object: nil)
        }
        nc.post(name: .syncedSettingsDidImport, object: nil)
    }

    // MARK: - Pure helpers (testable without touching the filesystem)

    /// The subset of `PreferencesManager.Keys` (which is private) that `importFromStore` needs by
    /// name to decide which live-update notifications to post. These are stable UserDefaults keys.
    enum SyncKeys {
        static let editorFontName = "editorFontName"
        static let editorFontSize = "editorFontSize"
        static let noteAlwaysOnTop = "noteAlwaysOnTop"
    }

    /// The set of syncable keys whose value differs between two snapshots. A key present in only
    /// one snapshot counts as changed; equal values (compared via `NSObject.isEqual`) do not.
    static func changedKeys(before: [String: Any], after: [String: Any]) -> Set<String> {
        var changed = Set<String>()
        for key in PreferencesManager.syncableKeys {
            let b = before[key]
            let a = after[key]
            switch (b, a) {
            case (nil, nil):
                continue
            case let (bv?, av?) where (bv as? NSObject)?.isEqual(av) == true:
                continue
            default:
                changed.insert(key)
            }
        }
        return changed
    }

    /// Snapshot the whitelisted settings that currently have a stored value.
    static func syncableValues(from defaults: UserDefaults) -> [String: Any] {
        var out: [String: Any] = [:]
        for key in PreferencesManager.syncableKeys {
            if let value = defaults.object(forKey: key) { out[key] = value }
        }
        return out
    }

    /// Apply a snapshot back into UserDefaults. Only whitelisted keys are honored, so a tampered
    /// or malformed file can never write the store path or other device-local values.
    static func apply(_ values: [String: Any], to defaults: UserDefaults) {
        let allowed = Set(PreferencesManager.syncableKeys)
        for (key, value) in values where allowed.contains(key) {
            defaults.set(value, forKey: key)
        }
    }

    /// Serialize to an XML property list (diff-friendly for file-sync tools, and natively handles
    /// the mix of Int/Double/String/Bool/Data that these settings use).
    static func serialize(_ values: [String: Any]) -> Data? {
        try? PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
    }

    static func deserialize(_ data: Data) -> [String: Any]? {
        (try? PropertyListSerialization.propertyList(from: data, options: [], format: nil)) as? [String: Any]
    }
}
