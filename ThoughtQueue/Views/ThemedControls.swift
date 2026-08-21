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
        heightAnchor.constraint(equalToConstant: Theme.metric(32)).isActive = true
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
        size.height = max(size.height, Theme.metric(32))
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
        heightAnchor.constraint(equalToConstant: Theme.metric(30)).isActive = true

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
        heightAnchor.constraint(equalToConstant: Theme.metric(26)).isActive = true

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

/// A custom-drawn checkbox in the Organic palette: a soft accent fill with an accent checkmark
/// when on, a bordered box on the surface color when off, centered in a generous square hit
/// target that grows with the interface text-size preference.
///
/// Drawn in `draw(_:)` rather than through `updateLayer()` because it strokes a box and a
/// checkmark rather than filling one rectangle. Drawing with live `NSColor`s (not cached
/// `cgColor`s) is also what keeps it correct across light/dark appearance changes.
final class ThemedCheckbox: NSButton {
    var isChecked = false {
        didSet {
            guard isChecked != oldValue else { return }
            state = isChecked ? .on : .off
            setAccessibilityValue(isChecked)
            needsDisplay = true
        }
    }

    /// Fires on a click or a Space/Return press, with the new state.
    var onToggle: ((Bool) -> Void)?

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
        }
    }
    private var trackingArea: NSTrackingArea?

    init() {
        super.init(frame: .zero)
        title = ""
        isBordered = false
        setButtonType(.toggle)
        translatesAutoresizingMaskIntoConstraints = false
        target = self
        action = #selector(clicked)
        setAccessibilityRole(.checkBox)
        setAccessibilityValue(false)
    }

    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: Theme.metric(28), height: Theme.metric(28))
    }

    override var acceptsFirstResponder: Bool { true }
    override func becomeFirstResponder() -> Bool { needsDisplay = true; return super.becomeFirstResponder() }
    override func resignFirstResponder() -> Bool { needsDisplay = true; return super.resignFirstResponder() }

    @objc private func clicked() {
        isChecked.toggle()
        onToggle?(isChecked)
    }

    /// Space and Return toggle while focused; everything else falls through so the checklist's
    /// arrow-key navigation still works.
    override func keyDown(with event: NSEvent) {
        if event.charactersIgnoringModifiers == " " || event.keyCode == 36 {
            clicked()
            return
        }
        super.keyDown(with: event)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self,
                                  userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func draw(_ dirtyRect: NSRect) {
        let side = Theme.metric(16)
        let box = NSRect(x: (bounds.width - side) / 2, y: (bounds.height - side) / 2,
                         width: side, height: side)
        let radius = max(Theme.radiusSmall - 2, 2)
        let path = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

        if isChecked {
            Theme.accentSoftBackground.setFill()
            Theme.accentBorder.setStroke()
        } else {
            (hovering ? Theme.hoverRow : Theme.surface).setFill()
            (hovering ? Theme.accentSoftBorder : Theme.fieldBorder).setStroke()
        }
        path.fill()
        path.lineWidth = 1
        path.stroke()

        if isChecked {
            // Built from the box's own top/bottom rather than raw minY/maxY, so the tick reads
            // the same way whichever vertical direction the drawing context runs in.
            let low = isFlipped ? box.maxY : box.minY
            let high = isFlipped ? box.minY : box.maxY
            let toward: (CGFloat, CGFloat) -> CGFloat = { edge, amount in
                edge + (self.isFlipped ? -amount : amount)
            }
            let check = NSBezierPath()
            check.move(to: NSPoint(x: box.minX + side * 0.24, y: toward(low, side * 0.52)))
            check.line(to: NSPoint(x: box.minX + side * 0.43, y: toward(low, side * 0.26)))
            check.line(to: NSPoint(x: box.maxX - side * 0.20, y: toward(high, -side * 0.25)))
            check.lineWidth = max(Theme.metric(2), 1.5)
            check.lineCapStyle = .round
            check.lineJoinStyle = .round
            Theme.accentBorder.setStroke()
            check.stroke()
        }

        if window?.firstResponder === self {
            let ring = NSBezierPath(roundedRect: box.insetBy(dx: -3, dy: -3),
                                    xRadius: radius + 3, yRadius: radius + 3)
            ring.lineWidth = 2
            Theme.accent.setStroke()
            ring.stroke()
        }
    }
}
