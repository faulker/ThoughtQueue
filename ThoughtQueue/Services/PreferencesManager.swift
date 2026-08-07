import Cocoa
import ServiceManagement

/// A global-hotkey binding (CGEvent keycode + modifier flags).
struct KeyBinding {
    let keyCode: Int64
    let modifiers: CGEventFlags

    static let defaultQuickCapture = KeyBinding(keyCode: 11, modifiers: [.maskCommand, .maskShift])               // Cmd+Shift+B
    static let defaultDetailedCapture = KeyBinding(keyCode: 11, modifiers: [.maskCommand, .maskShift, .maskAlternate]) // Cmd+Shift+Option+B
}

extension Notification.Name {
    /// Posted when the note editor font changes, so open views can re-render.
    static let editorFontDidChange = Notification.Name("editorFontDidChange")
    /// Posted when the "keep notes on top" preference changes, so open note windows
    /// can update their window level immediately.
    static let noteAlwaysOnTopDidChange = Notification.Name("noteAlwaysOnTopDidChange")
    /// Posted when the settings-sync toggle flips, so the sync mirror can start or stop.
    static let syncSettingsEnabledDidChange = Notification.Name("syncSettingsEnabledDidChange")
    /// Posted when the update-check toggle or interval changes, so the scheduler re-arms.
    static let updateCheckSettingsDidChange = Notification.Name("updateCheckSettingsDidChange")
}

/// How clicking a note in the UI behaves.
enum ClickBehavior: String {
    case openCommand    // run the default open-with action
    case renderMarkdown // render the markdown in-app
    case editRaw        // open a raw editor in-app
}

/// The app's appearance override. `system` (the default) just follows macOS; `light`/`dark`
/// pin `NSApp.appearance` regardless of the system setting.
enum ThemeMode: String {
    case light, dark, system
}

/// How the note editor's body text box enters edit mode when a note opens.
enum NoteEditMode: String {
    case doubleClick  // open in view mode; double-click (or type/paste) to edit
    case singleClick  // open in view mode; a single click enters edit
    case alwaysEdit   // open directly in raw-edit mode
}

/// UserDefaults-backed app configuration. Never writes anything into the store folder.
final class PreferencesManager {
    static let shared = PreferencesManager()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let quickCaptureKeyCode = "quickCaptureKeyCode"
        static let quickCaptureModifiers = "quickCaptureModifiers"
        static let detailedCaptureKeyCode = "detailedCaptureKeyCode"
        static let detailedCaptureModifiers = "detailedCaptureModifiers"
        static let storeBookmark = "storeFolderBookmark"
        static let storePath = "storeFolderPath"
        static let workingDocPath = "workingDocumentPath"
        static let clickBehavior = "clickBehavior"
        static let noteEditMode = "noteEditMode"
        static let toastTimeout = "toastTimeout"
        static let openWithActions = "openWithActions"
        static let autoIntelEnabled = "autoIntelEnabled"
        static let editorFontName = "editorFontName"
        static let editorFontSize = "editorFontSize"
        static let noteAlwaysOnTop = "noteAlwaysOnTop"
        static let noteWindowWidth = "noteWindowWidth"
        static let noteWindowHeight = "noteWindowHeight"
        static let noteNavigatorWidth = "noteNavigatorWidth"
        static let syncSettings = "syncSettingsEnabled"
        static let autoUpdateCheckEnabled = "autoUpdateCheckEnabled"
        static let updateCheckIntervalHours = "updateCheckIntervalHours"
        static let lastUpdateCheckAt = "lastUpdateCheckAt"
        static let themeMode = "themeMode"
    }

    private init() {}

    // MARK: - Settings sync

    /// Keys that are safe to mirror into the store folder for cross-device sync.
    /// Deliberately a whitelist: device-local values (the store bookmark/path, the working
    /// document's absolute path, and the sync toggle itself) are never included, so they can
    /// never leak between machines even if the synced file is edited by hand.
    static let syncableKeys: [String] = [
        Keys.quickCaptureKeyCode, Keys.quickCaptureModifiers,
        Keys.detailedCaptureKeyCode, Keys.detailedCaptureModifiers,
        Keys.clickBehavior, Keys.noteEditMode,
        Keys.toastTimeout, Keys.openWithActions, Keys.autoIntelEnabled,
        Keys.editorFontName, Keys.editorFontSize,
        Keys.noteAlwaysOnTop, Keys.noteWindowWidth, Keys.noteWindowHeight,
        Keys.noteNavigatorWidth,
        Keys.autoUpdateCheckEnabled, Keys.updateCheckIntervalHours,
        Keys.themeMode,
    ]

    /// Whether syncable settings are mirrored into the store folder so other devices pointed at
    /// the same (cloud-synced) folder pick them up. On by default; when off, settings stay in
    /// local UserDefaults only. The flag itself is always local and never synced.
    var syncSettingsEnabled: Bool {
        get { defaults.object(forKey: Keys.syncSettings) == nil ? true : defaults.bool(forKey: Keys.syncSettings) }
        set {
            defaults.set(newValue, forKey: Keys.syncSettings)
            NotificationCenter.default.post(name: .syncSettingsEnabledDidChange, object: nil)
        }
    }

    // MARK: - Hotkeys

    var quickCaptureKey: KeyBinding {
        get { loadBinding(keyCodeKey: Keys.quickCaptureKeyCode, modifiersKey: Keys.quickCaptureModifiers, default: .defaultQuickCapture) }
        set { saveBinding(newValue, keyCodeKey: Keys.quickCaptureKeyCode, modifiersKey: Keys.quickCaptureModifiers) }
    }

    var detailedCaptureKey: KeyBinding {
        get { loadBinding(keyCodeKey: Keys.detailedCaptureKeyCode, modifiersKey: Keys.detailedCaptureModifiers, default: .defaultDetailedCapture) }
        set { saveBinding(newValue, keyCodeKey: Keys.detailedCaptureKeyCode, modifiersKey: Keys.detailedCaptureModifiers) }
    }

    private func loadBinding(keyCodeKey: String, modifiersKey: String, default fallback: KeyBinding) -> KeyBinding {
        guard defaults.object(forKey: keyCodeKey) != nil else { return fallback }
        let keyCode = Int64(defaults.integer(forKey: keyCodeKey))
        let modRaw: UInt64
        if let modString = defaults.string(forKey: modifiersKey) {
            modRaw = UInt64(modString) ?? fallback.modifiers.rawValue
        } else {
            modRaw = UInt64(bitPattern: Int64(defaults.integer(forKey: modifiersKey)))
        }
        return KeyBinding(keyCode: keyCode, modifiers: CGEventFlags(rawValue: modRaw))
    }

    private func saveBinding(_ binding: KeyBinding, keyCodeKey: String, modifiersKey: String) {
        defaults.set(Int(binding.keyCode), forKey: keyCodeKey)
        defaults.set(String(binding.modifiers.rawValue), forKey: modifiersKey)
    }

    // MARK: - Store location

    /// The chosen store folder. Persisted as a security-scoped bookmark (with a plain
    /// path fallback) so it survives relaunch on a non-sandboxed build.
    var storeURL: URL? {
        get {
            if let data = defaults.data(forKey: Keys.storeBookmark) {
                var stale = false
                if let url = try? URL(resolvingBookmarkData: data, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale) {
                    return url
                }
            }
            if let path = defaults.string(forKey: Keys.storePath) {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return nil
        }
        set {
            guard let url = newValue else {
                defaults.removeObject(forKey: Keys.storeBookmark)
                defaults.removeObject(forKey: Keys.storePath)
                return
            }
            defaults.set(url.path, forKey: Keys.storePath)
            if let data = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil) {
                defaults.set(data, forKey: Keys.storeBookmark)
            }
        }
    }

    /// Proposed default store location used by the first-run chooser.
    var defaultStoreURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return docs.appendingPathComponent("ThoughtQueue", isDirectory: true)
    }

    // MARK: - Working document

    /// The designated default capture sink (a note's absolute path), if set.
    var workingDocumentURL: URL? {
        get {
            guard let path = defaults.string(forKey: Keys.workingDocPath) else { return nil }
            return URL(fileURLWithPath: path)
        }
        set {
            defaults.set(newValue?.path, forKey: Keys.workingDocPath)
            NotificationCenter.default.post(name: .notesDidChange, object: nil)
        }
    }

    // MARK: - Appearance

    /// The app's appearance override. `system` (the default) by setting `NSApp.appearance = nil`
    /// on read, so the app just follows macOS unless the user pins light or dark. Applying it is
    /// a side effect of the setter, both at launch and whenever Preferences changes it, so there
    /// is exactly one place this ever needs calling from.
    var themeMode: ThemeMode {
        get { ThemeMode(rawValue: defaults.string(forKey: Keys.themeMode) ?? "") ?? .system }
        set {
            defaults.set(newValue.rawValue, forKey: Keys.themeMode)
            Self.applyThemeMode(newValue)
        }
    }

    /// Push `mode` onto the running app. Safe to call at any time, including at launch to apply
    /// a previously-stored non-default preference (the default `.system` needs no action, since
    /// `NSApp.appearance` already starts `nil`).
    static func applyThemeMode(_ mode: ThemeMode) {
        switch mode {
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .system: NSApp.appearance = nil
        }
    }

    // MARK: - Click behavior

    var clickBehavior: ClickBehavior {
        get { ClickBehavior(rawValue: defaults.string(forKey: Keys.clickBehavior) ?? "") ?? .renderMarkdown }
        set { defaults.set(newValue.rawValue, forKey: Keys.clickBehavior) }
    }

    /// How the note editor's body enters edit mode when a note window opens.
    var noteEditMode: NoteEditMode {
        get { NoteEditMode(rawValue: defaults.string(forKey: Keys.noteEditMode) ?? "") ?? .doubleClick }
        set { defaults.set(newValue.rawValue, forKey: Keys.noteEditMode) }
    }

    // MARK: - Note editor font

    /// Default size used when none is stored.
    static let defaultEditorFontSize: CGFloat = 13

    /// Resolve a font from a stored PostScript name + size, falling back to the system font.
    /// Pure helper so the resolution logic is testable without touching UserDefaults.
    static func resolveEditorFont(name: String?, size: Double) -> NSFont {
        let pointSize = size > 0 ? CGFloat(size) : defaultEditorFontSize
        if let name = name, let font = NSFont(name: name, size: pointSize) {
            return font
        }
        return .systemFont(ofSize: pointSize)
    }

    /// The font used when editing and rendering a note's body. Persisted as PostScript name + size.
    var editorFont: NSFont {
        get { Self.resolveEditorFont(name: defaults.string(forKey: Keys.editorFontName), size: defaults.double(forKey: Keys.editorFontSize)) }
        set {
            defaults.set(newValue.fontName, forKey: Keys.editorFontName)
            defaults.set(Double(newValue.pointSize), forKey: Keys.editorFontSize)
            NotificationCenter.default.post(name: .editorFontDidChange, object: nil)
        }
    }

    // MARK: - Toast timeout

    var toastTimeout: TimeInterval {
        get {
            let v = defaults.double(forKey: Keys.toastTimeout)
            return v > 0 ? v : 8.0
        }
        set { defaults.set(newValue, forKey: Keys.toastTimeout) }
    }

    // MARK: - Notes always on top

    /// When true, note windows float above other apps' windows (NSWindow.level = .floating).
    /// Off by default. Changing it posts `.noteAlwaysOnTopDidChange` so open windows update live.
    var noteAlwaysOnTop: Bool {
        get { defaults.bool(forKey: Keys.noteAlwaysOnTop) }
        set {
            defaults.set(newValue, forKey: Keys.noteAlwaysOnTop)
            NotificationCenter.default.post(name: .noteAlwaysOnTopDidChange, object: nil)
        }
    }

    // MARK: - Note window size

    /// The default note window size, used until the user resizes a note window.
    static let defaultNoteWindowSize = NSSize(width: 460, height: 520)

    /// The last size the user resized a note window to, remembered so every subsequently
    /// opened note window uses it. Falls back to `defaultNoteWindowSize` when unset.
    var noteWindowSize: NSSize {
        get {
            let width = defaults.double(forKey: Keys.noteWindowWidth)
            let height = defaults.double(forKey: Keys.noteWindowHeight)
            guard width > 0, height > 0 else { return Self.defaultNoteWindowSize }
            return NSSize(width: width, height: height)
        }
        set {
            defaults.set(Double(newValue.width), forKey: Keys.noteWindowWidth)
            defaults.set(Double(newValue.height), forKey: Keys.noteWindowHeight)
        }
    }

    // MARK: - Note navigator width

    /// The default width of the note window's navigation panel.
    static let defaultNoteNavigatorWidth: CGFloat = 200

    /// The width of the note window's navigation panel, remembered when the user drags the
    /// divider. Clamped to the split view item's allowed thickness range. The panel's
    /// visibility is deliberately not persisted: it always starts hidden.
    var noteNavigatorWidth: CGFloat {
        get {
            let width = defaults.double(forKey: Keys.noteNavigatorWidth)
            guard width > 0 else { return Self.defaultNoteNavigatorWidth }
            return min(max(CGFloat(width), 160), 320)
        }
        set { defaults.set(Double(min(max(newValue, 160), 320)), forKey: Keys.noteNavigatorWidth) }
    }

    // MARK: - Auto-intel toggle

    var autoIntelEnabled: Bool {
        get { defaults.object(forKey: Keys.autoIntelEnabled) == nil ? true : defaults.bool(forKey: Keys.autoIntelEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoIntelEnabled) }
    }

    // MARK: - Updates

    /// The interval used when nothing is stored yet, and the bounds a stored value is clamped to.
    static let defaultUpdateCheckIntervalHours = 24

    /// Whether ThoughtQueue checks GitHub Releases for a newer version at launch and on an
    /// interval. On by default. Changing it posts `.updateCheckSettingsDidChange` so
    /// `UpdateService` re-arms its timer immediately.
    var autoUpdateCheckEnabled: Bool {
        get { defaults.object(forKey: Keys.autoUpdateCheckEnabled) == nil ? true : defaults.bool(forKey: Keys.autoUpdateCheckEnabled) }
        set {
            defaults.set(newValue, forKey: Keys.autoUpdateCheckEnabled)
            NotificationCenter.default.post(name: .updateCheckSettingsDidChange, object: nil)
        }
    }

    /// How many hours between automatic update checks. Clamped to between an hour and a week so
    /// a hand-edited or synced value can't produce a runaway timer.
    var updateCheckIntervalHours: Int {
        get {
            let hours = defaults.integer(forKey: Keys.updateCheckIntervalHours)
            guard hours > 0 else { return Self.defaultUpdateCheckIntervalHours }
            return min(max(hours, 1), 168)
        }
        set {
            defaults.set(min(max(newValue, 1), 168), forKey: Keys.updateCheckIntervalHours)
            NotificationCenter.default.post(name: .updateCheckSettingsDidChange, object: nil)
        }
    }

    /// When the last update check completed, successful or not. Device-local: never synced,
    /// since another Mac's check says nothing about this one.
    var lastUpdateCheckAt: Date? {
        get {
            let stamp = defaults.double(forKey: Keys.lastUpdateCheckAt)
            return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
        }
        set { defaults.set(newValue?.timeIntervalSince1970 ?? 0, forKey: Keys.lastUpdateCheckAt) }
    }

    // MARK: - Open-with actions

    /// The configured open-with actions; seeded with Claude + Zed presets on first read.
    var openWithActions: [OpenWithAction] {
        get {
            guard let data = defaults.data(forKey: Keys.openWithActions),
                  let actions = try? JSONDecoder().decode([OpenWithAction].self, from: data),
                  !actions.isEmpty else {
                return OpenWithAction.presets
            }
            return actions
        }
        set {
            if let data = try? JSONEncoder().encode(newValue) {
                defaults.set(data, forKey: Keys.openWithActions)
            }
        }
    }

    /// The default open-with action (first in the list) used by the open-command click behavior.
    var defaultOpenWithAction: OpenWithAction? {
        openWithActions.first
    }

    // MARK: - Start at login

    var startAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Failed to \(newValue ? "enable" : "disable") start at login: \(error)")
            }
        }
    }
}
