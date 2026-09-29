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

/// The app's visual identity: color tokens resolved through the active light/dark `ThemePalette`
/// (Organic by default, see `ThemeLibrary` for built-in and custom themes), Figtree for UI text,
/// Georgia for the bold accent labels the design uses on buttons and section headers, and shared
/// corner-radius constants. Every color is dynamic, so views built from these tokens repaint
/// correctly when the appearance or theme changes; nothing here needs manual light/dark handling
/// at the call site.
enum Theme {

    // MARK: - Active palettes

    /// The palette used whenever the effective appearance is light. Set by `ThemeLibrary`.
    static var lightPalette: ThemePalette = .organicLight
    /// The palette used whenever the effective appearance is dark. Set by `ThemeLibrary`.
    static var darkPalette: ThemePalette = .organicDark

    /// The palette a given appearance draws with.
    static func palette(for appearance: NSAppearance) -> ThemePalette {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? darkPalette : lightPalette
    }

    /// A dynamic color that looks the token up in whichever palette is active for the drawing
    /// appearance, re-evaluated on every draw, so swapping `lightPalette`/`darkPalette` (plus a
    /// redraw) retints everything built from these tokens.
    private static func token(_ path: KeyPath<ThemePalette, NSColor>) -> NSColor {
        NSColor(name: nil) { appearance in palette(for: appearance)[keyPath: path] }
    }

    // MARK: - Surfaces

    /// Card/window content background (popover, note window, settings, sidebar panels).
    static let surface = token(\.surface)
    /// Input/search field and "pill" background.
    static let fieldBackground = token(\.fieldBackground)
    static let fieldBorder = token(\.fieldBorder)
    /// A row's background on hover/highlight (notes list, collections list).
    static let hoverRow = token(\.hoverRow)
    /// Hairline dividers and card borders.
    static let divider = token(\.divider)

    // MARK: - Text & icons

    static let textPrimary = token(\.textPrimary)
    static let textSecondary = token(\.textSecondary)
    static let iconStroke = token(\.iconStroke)

    // MARK: - Accent

    static let accent = token(\.accent)
    static let accentBorder = token(\.accentBorder)
    /// Text/icon color drawn on top of a solid `accent` fill.
    static let accentText = token(\.accentText)
    /// A soft accent wash used for selected rows, checked checkboxes, and the pinned-state button.
    static let accentSoftBackground = token(\.accentSoftBackground)
    static let accentSoftBorder = token(\.accentSoftBorder)
    /// A lighter accent wash for a selected list row (subtler than `accentSoftBackground`).
    static let accentSelectionBackground = token(\.accentSelectionBackground)

    static let danger = token(\.danger)

    /// Background behind a hovered icon-only button (row actions, header icons).
    static let iconHoverBackground = token(\.iconHoverBackground)

    // MARK: - Category tints

    struct CategoryTint {
        let background: NSColor
        let foreground: NSColor
    }

    /// A stable tint for a category name, drawn from the active palette's `categoryTints`
    /// (each appearance's list may have its own length, so the index wraps per palette).
    static func categoryTint(for name: String) -> CategoryTint {
        let index = abs(name.hashValue)
        func pick(_ appearance: NSAppearance) -> ThemePalette.Tint {
            let tints = palette(for: appearance).categoryTints
            return tints[index % tints.count]
        }
        return CategoryTint(
            background: NSColor(name: nil) { pick($0).background },
            foreground: NSColor(name: nil) { pick($0).foreground }
        )
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
