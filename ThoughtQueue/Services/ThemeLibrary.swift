import Cocoa

extension Notification.Name {
    /// Posted after the active light/dark palettes change (selection or a reload of custom files).
    static let themeDidChange = Notification.Name("themeDidChange")
}

/// Owns the list of available themes (built-ins plus custom JSON files in the Themes folder) and
/// pushes the user's light/dark choice into `Theme`. Custom files are only read on `reload()`,
/// which runs at launch, on import, and from the Preferences "Reload" button.
final class ThemeLibrary {
    static let shared = ThemeLibrary()

    /// A theme file that failed to load, with a human-readable reason for Preferences to show.
    struct LoadFailure: Equatable {
        let fileName: String
        let reason: String
    }

    enum ImportError: Error, CustomStringConvertible {
        case invalid(String)
        case copyFailed(String)

        var description: String {
            switch self {
            case .invalid(let reason): return reason
            case .copyFailed(let reason): return "Couldn't copy the file: \(reason)"
            }
        }
    }

    private(set) var themes: [ThemePalette] = ThemePalette.builtIns
    private(set) var failures: [LoadFailure] = []

    /// `~/Library/Application Support/ThoughtQueue/Themes`. Created on demand.
    let folderURL: URL

    init(folderURL: URL? = nil) {
        self.folderURL = folderURL ?? FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ThoughtQueue/Themes", isDirectory: true)
    }

    /// Themes designed for one appearance, built-ins first.
    func themes(for appearance: ThemeAppearance) -> [ThemePalette] {
        themes.filter { $0.appearance == appearance }
    }

    /// The theme with `id` if it exists for that appearance, else that appearance's Organic
    /// built-in (so a synced id for a custom theme missing on this Mac degrades gracefully).
    func resolve(id: String?, appearance: ThemeAppearance) -> ThemePalette {
        if let id, let match = themes.first(where: { $0.id == id && $0.appearance == appearance }) {
            return match
        }
        return appearance == .dark ? .organicDark : .organicLight
    }

    /// Re-scan the Themes folder. Built-ins always come first; custom themes follow sorted by name.
    func reload() {
        let (custom, failures) = Self.loadCustomThemes(in: folderURL)
        themes = ThemePalette.builtIns + custom
        self.failures = failures
        for failure in failures {
            NSLog("ThoughtQueue: theme \(failure.fileName) failed to load: \(failure.reason)")
        }
    }

    /// Read every `*.json` in `folder`. A missing folder is simply no custom themes. Pure apart
    /// from reading the folder, so it is testable against a temp directory.
    static func loadCustomThemes(in folder: URL) -> (themes: [ThemePalette], failures: [LoadFailure]) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return ([], []) }

        var themes: [ThemePalette] = []
        var failures: [LoadFailure] = []
        for file in files where file.pathExtension.lowercased() == "json" {
            do {
                let data = try Data(contentsOf: file)
                themes.append(try ThemePalette.decode(data, id: customID(for: file)))
            } catch let error as ThemePalette.DecodeError {
                failures.append(LoadFailure(fileName: file.lastPathComponent, reason: error.description))
            } catch {
                failures.append(LoadFailure(fileName: file.lastPathComponent, reason: error.localizedDescription))
            }
        }
        themes.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        failures.sort { $0.fileName < $1.fileName }
        return (themes, failures)
    }

    /// Preference id for a custom theme file: `custom:` plus the file name without extension.
    static func customID(for file: URL) -> String {
        "custom:" + file.deletingPathExtension().lastPathComponent
    }

    /// Validate `source` as a theme, copy it into the Themes folder (replacing a same-named file),
    /// and reload. Returns the imported theme so the caller can select it.
    @discardableResult
    func importTheme(from source: URL) throws -> ThemePalette {
        let destination = folderURL.appendingPathComponent(source.lastPathComponent)
        do {
            _ = try ThemePalette.decode(Data(contentsOf: source), id: Self.customID(for: destination))
        } catch let error as ThemePalette.DecodeError {
            throw ImportError.invalid(error.description)
        } catch {
            throw ImportError.invalid(error.localizedDescription)
        }
        do {
            try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
            if source.standardizedFileURL != destination.standardizedFileURL {
                if FileManager.default.fileExists(atPath: destination.path) {
                    try FileManager.default.removeItem(at: destination)
                }
                try FileManager.default.copyItem(at: source, to: destination)
            }
        } catch {
            throw ImportError.copyFailed(error.localizedDescription)
        }
        reload()
        let id = Self.customID(for: destination)
        guard let theme = themes.first(where: { $0.id == id }) else {
            throw ImportError.invalid("The theme didn't load after copying.")
        }
        return theme
    }

    /// Create the Themes folder if needed and return it (for "Open Themes Folder").
    func ensureFolder() throws -> URL {
        try FileManager.default.createDirectory(at: folderURL, withIntermediateDirectories: true)
        return folderURL
    }

    /// Push the stored light/dark selection into `Theme` and repaint every open window.
    func apply() {
        let prefs = PreferencesManager.shared
        Theme.lightPalette = resolve(id: prefs.lightThemeID, appearance: .light)
        Theme.darkPalette = resolve(id: prefs.darkThemeID, appearance: .dark)
        for window in NSApp?.windows ?? [] {
            if let content = window.contentView { Self.markForRedraw(content) }
            // The frame view hosts the titlebar area, which some windows paint with Theme colors.
            if let frame = window.contentView?.superview { frame.needsDisplay = true }
        }
        NotificationCenter.default.post(name: .themeDidChange, object: nil)
    }

    /// Dynamic colors only re-resolve when a view redraws, and layer-backed views that assign
    /// `cgColor` in `updateLayer()` need `needsDisplay` to run it again.
    private static func markForRedraw(_ view: NSView) {
        view.needsDisplay = true
        view.subviews.forEach(markForRedraw)
    }
}
