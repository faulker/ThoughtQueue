import Cocoa

/// One line of a checklist note. Subclasses cover the kinds the editor models: a task item, a
/// heading shown as a section label, a blank spacer, and anything else kept as plain text.
class ChecklistRowView: NSView {
    /// Index into the owning controller's `rows`, kept current by `renumber()`.
    var index: Int = 0
    weak var owner: ChecklistViewController?

    /// The editable field, if this row has one. Blank rows do not.
    var field: NSTextField? { nil }

    /// Leading inset for one level of markdown indentation.
    static let indentStep: CGFloat = 20

    func configure(with row: TaskList.Row) {}

    /// Display-only nesting depth. The indent string itself is preserved verbatim in the model
    /// regardless of what this returns.
    static func indentLevel(of indent: String) -> Int {
        var level = 0
        var spaces = 0
        for character in indent {
            if character == "\t" { level += 1 } else if character == " " { spaces += 1 }
        }
        return min(level + spaces / 2, 6)
    }

    /// A borderless field that reads as plain text until you click into it.
    static func makeField(font: NSFont, color: NSColor, placeholder: String?) -> NSTextField {
        let field = NSTextField()
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = font
        field.textColor = color
        field.placeholderString = placeholder
        field.lineBreakMode = .byWordWrapping
        field.cell?.wraps = true
        field.cell?.isScrollable = false
        field.maximumNumberOfLines = 0
        field.translatesAutoresizingMaskIntoConstraints = false
        return field
    }
}

/// A task item: an always-clickable checkbox plus its text.
final class ChecklistItemRowView: ChecklistRowView {
    private let checkbox = ThemedCheckbox()
    private let textField = ChecklistRowView.makeField(font: PreferencesManager.shared.editorFont,
                                                       color: Theme.textPrimary,
                                                       placeholder: "New item")
    private var leading: NSLayoutConstraint!

    override var field: NSTextField? { textField }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(checkbox)
        addSubview(textField)

        checkbox.onToggle = { [weak self] checked in
            guard let self else { return }
            self.owner?.checkboxToggledFromRow(at: self.index, to: checked)
        }

        leading = checkbox.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16)
        NSLayoutConstraint.activate([
            leading,
            checkbox.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            checkbox.widthAnchor.constraint(equalToConstant: Theme.metric(28)),
            checkbox.heightAnchor.constraint(equalToConstant: Theme.metric(28)),

            textField.leadingAnchor.constraint(equalTo: checkbox.trailingAnchor, constant: 6),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            textField.centerYAnchor.constraint(equalTo: checkbox.centerYAnchor),
            textField.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 4),
            bottomAnchor.constraint(greaterThanOrEqualTo: textField.bottomAnchor, constant: 4),
            bottomAnchor.constraint(greaterThanOrEqualTo: checkbox.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(with row: TaskList.Row) {
        guard case .task(let task) = row.kind else { return }
        checkbox.isChecked = task.checked
        checkbox.setAccessibilityLabel(task.text.isEmpty ? "New item" : task.text)
        leading.constant = 16 + CGFloat(Self.indentLevel(of: task.indent)) * Self.indentStep
        textField.font = PreferencesManager.shared.editorFont

        // A checked item reads as done: struck through and dimmed.
        if task.checked {
            let attributed = NSAttributedString(string: task.text, attributes: [
                .font: PreferencesManager.shared.editorFont,
                .foregroundColor: Theme.textSecondary,
                .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                .strikethroughColor: Theme.textSecondary,
            ])
            textField.attributedStringValue = attributed
        } else {
            textField.stringValue = task.text
            textField.textColor = Theme.textPrimary
        }
    }
}

/// A markdown heading, shown as a section label with no checkbox.
final class ChecklistHeadingRowView: ChecklistRowView {
    private let textField = ChecklistRowView.makeField(font: Theme.heading(15, bold: true),
                                                       color: Theme.textPrimary,
                                                       placeholder: "Section")
    private let rule = NSBox()
    private var topSpacing: NSLayoutConstraint!

    override var field: NSTextField? { textField }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        rule.boxType = .separator
        rule.translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        addSubview(rule)

        topSpacing = textField.topAnchor.constraint(equalTo: topAnchor, constant: Theme.metric(10))
        NSLayoutConstraint.activate([
            topSpacing,
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),

            rule.topAnchor.constraint(equalTo: textField.bottomAnchor, constant: 4),
            rule.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            rule.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottomAnchor.constraint(equalTo: rule.bottomAnchor, constant: 4),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(with row: TaskList.Row) {
        guard case .heading(let heading) = row.kind else { return }
        textField.stringValue = heading.text
        textField.font = Theme.heading(max(17 - CGFloat(heading.level), 12), bold: true)
        rule.isHidden = heading.level > 1
        topSpacing.constant = index == 0 ? 2 : Theme.metric(10)
    }
}

/// A blank source line. Invisible structure: it exists so blank lines round-trip, and it is not
/// focusable or part of the tab loop.
final class ChecklistBlankRowView: ChecklistRowView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: Theme.metric(6)).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
}

/// Any line the checklist does not model (a table row, a quote, `#tag`). Editable as its raw
/// text so nothing in the file becomes unreachable.
final class ChecklistOtherRowView: ChecklistRowView {
    private let textField = ChecklistRowView.makeField(font: PreferencesManager.shared.editorFont,
                                                       color: Theme.textSecondary,
                                                       placeholder: nil)
    override var field: NSTextField? { textField }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        addSubview(textField)
        NSLayoutConstraint.activate([
            textField.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            textField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            textField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            bottomAnchor.constraint(equalTo: textField.bottomAnchor, constant: 3),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override func configure(with row: TaskList.Row) {
        textField.stringValue = row.text
        textField.font = PreferencesManager.shared.editorFont
    }
}

/// The trailing "Add item" affordance: a ghost row that appends a new item when clicked.
final class ChecklistAddRowView: NSView {
    var onAdd: (() -> Void)?

    private let label = NSTextField(labelWithString: "Add item")
    private let ghost = ThemedCheckbox()

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        ghost.isEnabled = false
        ghost.alphaValue = 0.5
        label.font = PreferencesManager.shared.editorFont
        label.textColor = Theme.textSecondary
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(ghost)
        addSubview(label)
        NSLayoutConstraint.activate([
            ghost.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            ghost.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            ghost.widthAnchor.constraint(equalToConstant: Theme.metric(28)),
            ghost.heightAnchor.constraint(equalToConstant: Theme.metric(28)),
            label.leadingAnchor.constraint(equalTo: ghost.trailingAnchor, constant: 6),
            label.centerYAnchor.constraint(equalTo: ghost.centerYAnchor),
            bottomAnchor.constraint(equalTo: ghost.bottomAnchor, constant: 2),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) { onAdd?() }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 36 || event.charactersIgnoringModifiers == " " {
            onAdd?()
            return
        }
        super.keyDown(with: event)
    }
}
