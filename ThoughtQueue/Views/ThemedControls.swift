import Cocoa

/// A plain view that paints `Theme.surface` behind its subviews (the note window, popover, and
/// settings backgrounds). `CALayer.backgroundColor` is a `CGColor` snapshot resolved once at
/// assignment time, unlike an `NSColor` drawn directly, so it doesn't track light/dark appearance
/// changes on its own. Opting into `wantsUpdateLayer`/`updateLayer()` (Apple's recommended Dark
/// Mode pattern, already used by `NoteRowView`'s hover fill) makes AppKit re-resolve it whenever
/// the effective appearance changes, instead of it staying stuck at whatever appearance was
/// current when the view was created.
class ThemedSurfaceView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.surface.cgColor
    }
}

/// A pill-shaped button matching the design's bold Georgia buttons: a filled sage "prominent"
/// style (primary actions like "+ Add") and an outlined "secondary" style (e.g. "Open"). Custom
/// drawn (unbordered NSButton + layer) because AppKit's bezel styles can't take an arbitrary
/// fill/border/text color trio, only tint.
final class ThemedButton: NSButton {
    var isProminent: Bool { didSet { applyAppearance() } }

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            applyAppearance()
        }
    }

    override var wantsUpdateLayer: Bool { true }

    /// Re-resolves the fill/border `cgColor`s whenever AppKit needs the layer redrawn, including
    /// on an appearance change (see `ThemedSurfaceView`). The title's colors don't need the same
    /// treatment: `attributedTitle` holds live `NSColor` objects that the text system re-resolves
    /// on every draw, unlike a `cgColor`.
    override func updateLayer() {
        let fill = isProminent ? Theme.accent : Theme.surface
        layer?.backgroundColor = (hovering ? fill.blended(withFraction: 0.08, of: .black) ?? fill : fill).cgColor
        layer?.borderColor = (isProminent ? Theme.accentBorder : Theme.divider).cgColor
    }

    convenience init(title: String, prominent: Bool, target: AnyObject?, action: Selector) {
        self.init(prominent: prominent)
        self.title = title
        self.target = target
        self.action = action
        applyAppearance()
    }

    private init(prominent: Bool) {
        self.isProminent = prominent
        super.init(frame: .zero)
        isBordered = false
        setButtonType(.momentaryChange)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusMedium
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { fatalError() }

    override var title: String {
        didSet { applyAppearance() }
    }

    /// Removing the bezel also removes AppKit's automatic title insets, which left the pill
    /// hugging its text with no breathing room. Pad it back in explicitly.
    override var intrinsicContentSize: NSSize {
        var size = super.intrinsicContentSize
        if size.width > 0 { size.width += 32 }
        size.height = max(size.height, 32)
        return size
    }

    /// Track hover so the fill can dim slightly, matching the mockup's `:hover{filter:brightness(.94)}`.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func applyAppearance() {
        needsDisplay = true // triggers updateLayer() for the fill/border

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        attributedTitle = NSAttributedString(string: title, attributes: [
            .font: Theme.heading(12),
            .foregroundColor: isProminent ? Theme.accentText : Theme.textPrimary,
            .paragraphStyle: paragraph,
        ])
    }
}

/// A pill-shaped search field matching the design's flat cream/dark search bar: a magnifying-
/// glass glyph plus a borderless text field, in place of AppKit's system-chrome `NSSearchField`
/// (which can't be recolored to match a custom palette).
final class ThemedSearchField: NSView, NSTextFieldDelegate {
    /// Fires on every keystroke, mirroring `NSSearchField`'s live-search behavior.
    var onChange: ((String) -> Void)?

    private let textField = NSTextField()

    var stringValue: String {
        get { textField.stringValue }
        set { textField.stringValue = newValue }
    }

    var placeholderString: String? {
        get { textField.placeholderString }
        set { textField.placeholderString = newValue }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = Theme.fieldBackground.cgColor
        layer?.borderColor = Theme.fieldBorder.cgColor
    }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusMedium
        layer?.borderWidth = 1
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 30).isActive = true

        let icon = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = Theme.iconStroke
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.setContentHuggingPriority(.required, for: .horizontal)

        textField.isBordered = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = Theme.body(12.5)
        textField.textColor = Theme.textPrimary
        textField.delegate = self
        textField.translatesAutoresizingMaskIntoConstraints = false

        addSubview(icon)
        addSubview(textField)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 13),
            icon.heightAnchor.constraint(equalToConstant: 13),
            textField.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 7),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            textField.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    func controlTextDidChange(_ obj: Notification) {
        onChange?(textField.stringValue)
    }
}

/// A two-or-more-way segmented pill (e.g. the design's "SF Mono / Menlo" quick font toggle):
/// a themed track with a raised chip behind whichever option is selected.
final class SegmentedPillControl: NSView {
    private(set) var buttons: [NSButton] = []
    private(set) var selectedIndex = 0
    /// Fires when the user picks a different segment (not on programmatic `select`).
    var onSelect: ((Int) -> Void)?

    init(titles: [String]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = Theme.radiusMedium
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 26).isActive = true

        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        for (index, title) in titles.enumerated() {
            let button = NSButton(title: title, target: self, action: #selector(tapped(_:)))
            button.tag = index
            button.isBordered = false
            button.wantsLayer = true
            button.layer?.cornerRadius = Theme.radiusSmall
            stack.addArrangedSubview(button)
            buttons.append(button)
        }
        select(0)
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func tapped(_ sender: NSButton) {
        select(sender.tag)
        onSelect?(sender.tag)
    }

    /// Move the highlighted chip to `index` without firing `onSelect` (for initial/external state).
    func select(_ index: Int) {
        guard index >= 0, index < buttons.count else { return }
        selectedIndex = index
        applySelectionColors()
    }

    override var wantsUpdateLayer: Bool { true }

    /// Re-resolves the track and chip `cgColor`s whenever AppKit needs the layer redrawn,
    /// including on an appearance change (see `ThemedSurfaceView`). Without this, picking a new
    /// theme mode here recolors the app but leaves this very toggle's own chip stuck showing the
    /// appearance it was drawn under.
    override func updateLayer() {
        layer?.backgroundColor = Theme.fieldBackground.cgColor
        applySelectionColors()
    }

    private func applySelectionColors() {
        for (i, button) in buttons.enumerated() {
            let isSelected = i == selectedIndex
            button.layer?.backgroundColor = (isSelected ? Theme.surface : .clear).cgColor
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .center
            button.attributedTitle = NSAttributedString(string: button.title, attributes: [
                .font: Theme.body(11, weight: .semibold),
                .foregroundColor: isSelected ? Theme.textPrimary : Theme.textSecondary,
                .paragraphStyle: paragraph,
            ])
        }
    }
}
