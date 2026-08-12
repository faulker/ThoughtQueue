import Cocoa

extension NSColor {
    /// A dynamic color that resolves to `light` or `dark` based on the current appearance,
    /// re-evaluated live on every draw so it tracks system/window appearance changes without
    /// any manual refresh.
    convenience init(light: NSColor, dark: NSColor) {
        self.init(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    /// `#RRGGBB` (or `#RRGGBBAA`) convenience, used throughout `Theme` to keep the palette
    /// readable next to the hex values in the design mockup.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        if s.count == 6 { s += "ff" }
        var v: UInt64 = 0
        Scanner(string: s).scanHexInt64(&v)
        self.init(
            srgbRed: CGFloat((v >> 24) & 0xff) / 255,
            green: CGFloat((v >> 16) & 0xff) / 255,
            blue: CGFloat((v >> 8) & 0xff) / 255,
            alpha: CGFloat(v & 0xff) / 255
        )
    }
}

/// The app's "Organic" visual identity: a warm cream/sage palette in light mode with a matching
/// warm dark counterpart, Figtree for UI text, Georgia for the bold accent labels the design uses
/// on buttons and section headers, and shared corner-radius constants. Every color is a dynamic
/// `NSColor` pair so views built from these tokens repaint correctly when the system appearance
/// changes; nothing here needs manual light/dark handling at the call site.
enum Theme {

    // MARK: - Surfaces

    /// Card/window content background (popover, note window, settings, sidebar panels).
    static let surface = NSColor(light: NSColor(hex: "#f9f4ed"), dark: NSColor(hex: "#211e19"))
    /// Input/search field and "pill" background.
    static let fieldBackground = NSColor(light: NSColor(hex: "#ebddc5"), dark: NSColor(hex: "#34302a"))
    static let fieldBorder = NSColor(light: NSColor(hex: "#c0b6a5"), dark: NSColor(hex: "#4a453c"))
    /// A row's background on hover/highlight (notes list, collections list).
    static let hoverRow = NSColor(light: NSColor(hex: "#f2ead9"), dark: NSColor(hex: "#2a261f"))
    /// Hairline dividers and card borders.
    static let divider = NSColor(light: NSColor(hex: "#201e1d").withAlphaComponent(0.12),
                                  dark: NSColor.white.withAlphaComponent(0.12))

    // MARK: - Text & icons

    static let textPrimary = NSColor(light: NSColor(hex: "#201e1d"), dark: NSColor(hex: "#f1e9db"))
    static let textSecondary = NSColor(light: NSColor(hex: "#82796a"), dark: NSColor(hex: "#a89a86"))
    static let iconStroke = NSColor(light: NSColor(hex: "#645c50"), dark: NSColor(hex: "#b3a693"))

    // MARK: - Sage accent

    static let accent = NSColor(light: NSColor(hex: "#7a8a5e"), dark: NSColor(hex: "#8fa06d"))
    static let accentBorder = NSColor(light: NSColor(hex: "#56633f"), dark: NSColor(hex: "#6b7a4f"))
    /// Text/icon color drawn on top of a solid `accent` fill.
    static let accentText = NSColor(light: NSColor(hex: "#f0fae1"), dark: NSColor(hex: "#1c2410"))
    /// A soft accent wash used for selected rows, checked checkboxes, and the pinned-state button.
    static let accentSoftBackground = NSColor(light: NSColor(hex: "#ccdbb2"), dark: NSColor(hex: "#333d24"))
    static let accentSoftBorder = NSColor(light: NSColor(hex: "#aebf92"), dark: NSColor(hex: "#4c5a37"))
    /// A lighter accent wash for a selected list row (subtler than `accentSoftBackground`).
    static let accentSelectionBackground = NSColor(light: NSColor(hex: "#ebddc5"), dark: NSColor(hex: "#332f27"))

    static let danger = NSColor(light: NSColor(hex: "#c0301b"), dark: NSColor(hex: "#ff6b52"))

    /// Background behind a hovered icon-only button (row actions, header icons).
    static let iconHoverBackground = NSColor(light: NSColor.black.withAlphaComponent(0.06),
                                              dark: NSColor.white.withAlphaComponent(0.10))

    // MARK: - Category tints

    struct CategoryTint {
        let background: NSColor
        let foreground: NSColor
    }

    /// A small rotating palette of warm/sage tints for category pills and icons (the design has
    /// no per-category color data, so categories are assigned one deterministically by name).
    private static let categoryTints: [CategoryTint] = [
        CategoryTint(background: NSColor(light: NSColor(hex: "#fff2eb"), dark: NSColor(hex: "#3a2a1f")),
                     foreground: NSColor(light: NSColor(hex: "#8c491a"), dark: NSColor(hex: "#e8a06a"))),
        CategoryTint(background: NSColor(light: NSColor(hex: "#f0fae1"), dark: NSColor(hex: "#2c3322")),
                     foreground: NSColor(light: NSColor(hex: "#3d472b"), dark: NSColor(hex: "#b9cf94"))),
        CategoryTint(background: NSColor(light: NSColor(hex: "#ffe1d0"), dark: NSColor(hex: "#402c1f")),
                     foreground: NSColor(light: NSColor(hex: "#8c491a"), dark: NSColor(hex: "#eda876"))),
        CategoryTint(background: NSColor(light: NSColor(hex: "#e1eecc"), dark: NSColor(hex: "#29331f")),
                     foreground: NSColor(light: NSColor(hex: "#3d472b"), dark: NSColor(hex: "#c3d99e"))),
    ]

    /// A stable tint for a category name: the same name always maps to the same color within a
    /// run (and across runs, since it's derived from the string itself, not insertion order).
    static func categoryTint(for name: String) -> CategoryTint {
        let index = abs(name.hashValue) % categoryTints.count
        return categoryTints[index]
    }

    // MARK: - Corner radii

    static let radiusSmall: CGFloat = 6
    static let radiusRow: CGFloat = 10
    static let radiusMedium: CGFloat = 10
    static let radiusLarge: CGFloat = 14

    // MARK: - Fonts

    /// Sentinel stored in `PreferencesManager.uiFontFamily` to mean "the macOS system font"
    /// rather than a named installed family. Starts with a dot so it can never collide with a
    /// real family name.
    static let systemFamily = ".system"

    /// Scale a design point size (or a layout metric that has to grow with the text, like a row
    /// height) by the user's interface text-size preference. Pure so it is testable.
    static func scaled(_ points: CGFloat, scale: Double) -> CGFloat {
        points * CGFloat(PreferencesManager.clampUIFontScale(scale))
    }

    /// A layout metric scaled by the current interface text size, so rows and controls keep
    /// their proportions when the user bumps the UI font up.
    static func metric(_ points: CGFloat) -> CGFloat {
        scaled(points, scale: PreferencesManager.shared.uiFontScale)
    }

    /// Resolve an interface font from a stored family choice. `nil` uses the bundled Figtree
    /// (a variable font with named weight instances, registered via `ATSApplicationFontsPath`),
    /// `systemFamily` uses the system font, and any other value is an installed family name.
    /// Falls back to the system font at the same weight whenever a face can't be found.
    /// Pure so it is testable without UserDefaults.
    static func resolveUIFont(family: String?, size: CGFloat, weight: NSFont.Weight) -> NSFont {
        if family == systemFamily { return .systemFont(ofSize: size, weight: weight) }
        guard let family else {
            let name: String
            switch weight {
            case .semibold: name = "Figtree-SemiBold"
            case .medium: name = "Figtree-Medium"
            case .bold, .heavy, .black: name = "Figtree-Bold"
            default: name = "Figtree-Regular"
            }
            return NSFont(name: name, size: size) ?? .systemFont(ofSize: size, weight: weight)
        }
        let isBold = weight == .semibold || weight == .bold || weight == .heavy || weight == .black
        let traits: NSFontTraitMask = isBold ? .boldFontMask : .unboldFontMask
        // NSFontManager weights are 0–15, where 5 is regular and 9 is bold.
        let managerWeight = isBold ? 9 : 5
        if let font = NSFontManager.shared.font(withFamily: family, traits: traits, weight: managerWeight, size: size) {
            return font
        }
        return NSFont(name: family, size: size) ?? .systemFont(ofSize: size, weight: weight)
    }

    /// The app's body font at a design size, honoring the interface font family and text size
    /// preferences.
    static func body(_ size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let prefs = PreferencesManager.shared
        return resolveUIFont(family: prefs.uiFontFamily, size: scaled(size, scale: prefs.uiFontScale), weight: weight)
    }

    /// Georgia ships with macOS. Used for the design's bold serif accents (primary buttons,
    /// panel titles) — a deliberate contrast note against the Figtree body text. When the user
    /// picks a custom interface font, that family takes over here too, so the whole UI matches.
    static func heading(_ size: CGFloat, bold: Bool = true) -> NSFont {
        let prefs = PreferencesManager.shared
        let pointSize = scaled(size, scale: prefs.uiFontScale)
        if let family = prefs.uiFontFamily {
            return resolveUIFont(family: family, size: pointSize, weight: bold ? .bold : .regular)
        }
        let name = bold ? "Georgia-Bold" : "Georgia"
        return NSFont(name: name, size: pointSize) ?? .systemFont(ofSize: pointSize, weight: bold ? .bold : .regular)
    }
}
