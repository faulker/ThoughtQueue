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
}

/// How clicking a note in the UI behaves.
enum ClickBehavior: String {
    case openCommand    // run the default open-with action
    case renderMarkdown // render the markdown in-app
    case editRaw        // open a raw editor in-app
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
        static let toastTimeout = "toastTimeout"
        static let openWithActions = "openWithActions"
        static let autoIntelEnabled = "autoIntelEnabled"
        static let editorFontName = "editorFontName"
        static let editorFontSize = "editorFontSize"
    }

    private init() {}

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

    // MARK: - Click behavior

    var clickBehavior: ClickBehavior {
        get { ClickBehavior(rawValue: defaults.string(forKey: Keys.clickBehavior) ?? "") ?? .renderMarkdown }
        set { defaults.set(newValue.rawValue, forKey: Keys.clickBehavior) }
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

    // MARK: - Auto-intel toggle

    var autoIntelEnabled: Bool {
        get { defaults.object(forKey: Keys.autoIntelEnabled) == nil ? true : defaults.bool(forKey: Keys.autoIntelEnabled) }
        set { defaults.set(newValue, forKey: Keys.autoIntelEnabled) }
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
