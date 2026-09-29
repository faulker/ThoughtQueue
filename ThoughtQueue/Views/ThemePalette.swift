import Cocoa

/// Which system appearance a palette is designed for. A light palette is used whenever the app's
/// effective appearance is light, a dark one whenever it is dark; the user picks one of each.
enum ThemeAppearance: String {
    case light, dark
}

/// One complete set of color tokens for a single appearance. `Theme` resolves every color it
/// exposes through the active light or dark palette at draw time, so swapping a palette repaints
/// the whole UI without any view knowing themes exist.
///
/// Custom themes are JSON files (see `docs/themes.md`) decoded by `decode(_:id:)`. Any color a
/// file leaves out falls back to the built-in Organic palette of the same appearance, so a theme
/// can override just the accent and nothing else.
struct ThemePalette {
    struct Tint {
        var background: NSColor
        var foreground: NSColor
    }

    /// Stable identifier stored in preferences. Built-ins use a bare slug; custom files use
    /// `custom:<file name without extension>` so they can never shadow a built-in.
    var id: String
    var name: String
    var appearance: ThemeAppearance
    var isBuiltIn: Bool

    var surface: NSColor
    var fieldBackground: NSColor
    var fieldBorder: NSColor
    var hoverRow: NSColor
    var divider: NSColor
    var textPrimary: NSColor
    var textSecondary: NSColor
    var iconStroke: NSColor
    var accent: NSColor
    var accentBorder: NSColor
    var accentText: NSColor
    var accentSoftBackground: NSColor
    var accentSoftBorder: NSColor
    var accentSelectionBackground: NSColor
    var danger: NSColor
    var iconHoverBackground: NSColor
    /// Rotating category pill tints. Never empty.
    var categoryTints: [Tint]

    /// JSON key for every color token, in the order the docs list them. Decoding and the
    /// "unknown key" check both go through this table, so adding a token means adding one line.
    static let colorKeys: [(key: String, path: WritableKeyPath<ThemePalette, NSColor>)] = [
        ("surface", \.surface),
        ("fieldBackground", \.fieldBackground),
        ("fieldBorder", \.fieldBorder),
        ("hoverRow", \.hoverRow),
        ("divider", \.divider),
        ("textPrimary", \.textPrimary),
        ("textSecondary", \.textSecondary),
        ("iconStroke", \.iconStroke),
        ("accent", \.accent),
        ("accentBorder", \.accentBorder),
        ("accentText", \.accentText),
        ("accentSoftBackground", \.accentSoftBackground),
        ("accentSoftBorder", \.accentSoftBorder),
        ("accentSelectionBackground", \.accentSelectionBackground),
        ("danger", \.danger),
        ("iconHoverBackground", \.iconHoverBackground),
    ]

    // MARK: - Decoding

    enum DecodeError: Error, Equatable, CustomStringConvertible {
        case notJSONObject
        case missingField(String)
        case invalidAppearance(String)
        case invalidColor(key: String, value: String)
        case unknownColorKey(String)
        case invalidCategoryTints

        var description: String {
            switch self {
            case .notJSONObject: return "file is not a JSON object"
            case .missingField(let f): return "missing \"\(f)\""
            case .invalidAppearance(let v): return "appearance must be \"light\" or \"dark\", got \"\(v)\""
            case .invalidColor(let k, let v): return "\"\(k)\" is not a #RRGGBB or #RRGGBBAA color: \"\(v)\""
            case .unknownColorKey(let k): return "unknown color \"\(k)\""
            case .invalidCategoryTints: return "categoryTints must be a non-empty list of {background, foreground} colors"
            }
        }
    }

    /// Strict `#RRGGBB` / `#RRGGBBAA` parser for theme files. Unlike `NSColor(hex:)`, which
    /// quietly yields black for garbage, this returns nil so a typo is reported, not rendered.
    static func parseHex(_ string: String) -> NSColor? {
        let s = string.trimmingCharacters(in: .whitespaces)
        guard s.hasPrefix("#") else { return nil }
        let digits = s.dropFirst()
        guard digits.count == 6 || digits.count == 8,
              digits.allSatisfy({ $0.isHexDigit }) else { return nil }
        return NSColor(hex: String(digits))
    }

    /// Decode a theme file. Missing colors inherit from the built-in Organic palette matching the
    /// file's appearance; anything malformed throws rather than being skipped.
    static func decode(_ data: Data, id: String) throws -> ThemePalette {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw DecodeError.notJSONObject
        }
        guard let name = (root["name"] as? String)?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw DecodeError.missingField("name")
        }
        guard let appearanceRaw = root["appearance"] as? String else {
            throw DecodeError.missingField("appearance")
        }
        guard let appearance = ThemeAppearance(rawValue: appearanceRaw.lowercased()) else {
            throw DecodeError.invalidAppearance(appearanceRaw)
        }

        var palette = appearance == .dark ? organicDark : organicLight
        palette.id = id
        palette.name = name
        palette.isBuiltIn = false

        let colors = root["colors"] as? [String: Any] ?? [:]
        let known = Dictionary(uniqueKeysWithValues: colorKeys.map { ($0.key, $0.path) })
        for (key, value) in colors {
            guard let path = known[key] else { throw DecodeError.unknownColorKey(key) }
            guard let hex = value as? String, let color = parseHex(hex) else {
                throw DecodeError.invalidColor(key: key, value: "\(value)")
            }
            palette[keyPath: path] = color
        }

        if let rawTints = root["categoryTints"] {
            guard let list = rawTints as? [[String: Any]], !list.isEmpty else {
                throw DecodeError.invalidCategoryTints
            }
            palette.categoryTints = try list.map { entry in
                guard let bg = (entry["background"] as? String).flatMap(parseHex),
                      let fg = (entry["foreground"] as? String).flatMap(parseHex) else {
                    throw DecodeError.invalidCategoryTints
                }
                return Tint(background: bg, foreground: fg)
            }
        }
        return palette
    }

    // MARK: - Built-ins

    static let builtIns: [ThemePalette] = [organicLight, porcelain, organicDark, midnight]

    /// The original warm cream/sage light palette.
    static let organicLight = ThemePalette(
        id: "organic-light", name: "Organic Light", appearance: .light, isBuiltIn: true,
        surface: NSColor(hex: "#f9f4ed"),
        fieldBackground: NSColor(hex: "#ebddc5"),
        fieldBorder: NSColor(hex: "#c0b6a5"),
        hoverRow: NSColor(hex: "#f2ead9"),
        divider: NSColor(hex: "#201e1d").withAlphaComponent(0.12),
        textPrimary: NSColor(hex: "#201e1d"),
        textSecondary: NSColor(hex: "#82796a"),
        iconStroke: NSColor(hex: "#645c50"),
        accent: NSColor(hex: "#7a8a5e"),
        accentBorder: NSColor(hex: "#56633f"),
        accentText: NSColor(hex: "#f0fae1"),
        accentSoftBackground: NSColor(hex: "#ccdbb2"),
        accentSoftBorder: NSColor(hex: "#aebf92"),
        accentSelectionBackground: NSColor(hex: "#ebddc5"),
        danger: NSColor(hex: "#c0301b"),
        iconHoverBackground: NSColor.black.withAlphaComponent(0.06),
        categoryTints: [
            Tint(background: NSColor(hex: "#fff2eb"), foreground: NSColor(hex: "#8c491a")),
            Tint(background: NSColor(hex: "#f0fae1"), foreground: NSColor(hex: "#3d472b")),
            Tint(background: NSColor(hex: "#ffe1d0"), foreground: NSColor(hex: "#8c491a")),
            Tint(background: NSColor(hex: "#e1eecc"), foreground: NSColor(hex: "#3d472b")),
        ]
    )

    /// The original warm dark counterpart to Organic Light.
    static let organicDark = ThemePalette(
        id: "organic-dark", name: "Organic Dark", appearance: .dark, isBuiltIn: true,
        surface: NSColor(hex: "#211e19"),
        fieldBackground: NSColor(hex: "#34302a"),
        fieldBorder: NSColor(hex: "#4a453c"),
        hoverRow: NSColor(hex: "#2a261f"),
        divider: NSColor.white.withAlphaComponent(0.12),
        textPrimary: NSColor(hex: "#f1e9db"),
        textSecondary: NSColor(hex: "#a89a86"),
        iconStroke: NSColor(hex: "#b3a693"),
        accent: NSColor(hex: "#8fa06d"),
        accentBorder: NSColor(hex: "#6b7a4f"),
        accentText: NSColor(hex: "#1c2410"),
        accentSoftBackground: NSColor(hex: "#333d24"),
        accentSoftBorder: NSColor(hex: "#4c5a37"),
        accentSelectionBackground: NSColor(hex: "#332f27"),
        danger: NSColor(hex: "#ff6b52"),
        iconHoverBackground: NSColor.white.withAlphaComponent(0.10),
        categoryTints: [
            Tint(background: NSColor(hex: "#3a2a1f"), foreground: NSColor(hex: "#e8a06a")),
            Tint(background: NSColor(hex: "#2c3322"), foreground: NSColor(hex: "#b9cf94")),
            Tint(background: NSColor(hex: "#402c1f"), foreground: NSColor(hex: "#eda876")),
            Tint(background: NSColor(hex: "#29331f"), foreground: NSColor(hex: "#c3d99e")),
        ]
    )

    /// A cool, crisp light theme: near-white blue-gray surfaces with a slate-blue accent.
    static let porcelain = ThemePalette(
        id: "porcelain", name: "Porcelain", appearance: .light, isBuiltIn: true,
        surface: NSColor(hex: "#f7f8fa"),
        fieldBackground: NSColor(hex: "#e6eaf0"),
        fieldBorder: NSColor(hex: "#bcc4d0"),
        hoverRow: NSColor(hex: "#eef1f5"),
        divider: NSColor(hex: "#1b2330").withAlphaComponent(0.12),
        textPrimary: NSColor(hex: "#1b2330"),
        textSecondary: NSColor(hex: "#6a7485"),
        iconStroke: NSColor(hex: "#4f5a6b"),
        accent: NSColor(hex: "#4a6fa5"),
        accentBorder: NSColor(hex: "#35547f"),
        accentText: NSColor(hex: "#f4f8ff"),
        accentSoftBackground: NSColor(hex: "#cfdcf0"),
        accentSoftBorder: NSColor(hex: "#a9bee0"),
        accentSelectionBackground: NSColor(hex: "#e2e8f1"),
        danger: NSColor(hex: "#c62f3b"),
        iconHoverBackground: NSColor.black.withAlphaComponent(0.06),
        categoryTints: [
            Tint(background: NSColor(hex: "#e5edfa"), foreground: NSColor(hex: "#2f4f80")),
            Tint(background: NSColor(hex: "#e3f4f1"), foreground: NSColor(hex: "#1f5d55")),
            Tint(background: NSColor(hex: "#efe8fa"), foreground: NSColor(hex: "#553a85")),
            Tint(background: NSColor(hex: "#fbeae6"), foreground: NSColor(hex: "#8a3b2b")),
        ]
    )

    /// A deep navy dark theme with a soft teal accent, cooler than Organic Dark.
    static let midnight = ThemePalette(
        id: "midnight", name: "Midnight", appearance: .dark, isBuiltIn: true,
        surface: NSColor(hex: "#161b26"),
        fieldBackground: NSColor(hex: "#232a38"),
        fieldBorder: NSColor(hex: "#343d4f"),
        hoverRow: NSColor(hex: "#1d2330"),
        divider: NSColor.white.withAlphaComponent(0.10),
        textPrimary: NSColor(hex: "#e3e8f1"),
        textSecondary: NSColor(hex: "#8d97a8"),
        iconStroke: NSColor(hex: "#a3adbd"),
        accent: NSColor(hex: "#5fb3a8"),
        accentBorder: NSColor(hex: "#44867d"),
        accentText: NSColor(hex: "#0d1f1c"),
        accentSoftBackground: NSColor(hex: "#1f3a3a"),
        accentSoftBorder: NSColor(hex: "#2e5451"),
        accentSelectionBackground: NSColor(hex: "#262e3d"),
        danger: NSColor(hex: "#ff6b6b"),
        iconHoverBackground: NSColor.white.withAlphaComponent(0.10),
        categoryTints: [
            Tint(background: NSColor(hex: "#1e2c42"), foreground: NSColor(hex: "#8fb4ec")),
            Tint(background: NSColor(hex: "#1c3432"), foreground: NSColor(hex: "#86d1c6")),
            Tint(background: NSColor(hex: "#2c2442"), foreground: NSColor(hex: "#b9a2ec")),
            Tint(background: NSColor(hex: "#3a2628"), foreground: NSColor(hex: "#eea3a0")),
        ]
    )
}
