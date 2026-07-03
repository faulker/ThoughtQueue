import Cocoa

/// A single note row used in the popover. Shows the title + category and offers quick
/// actions: open-with (default action), copy path, and delete.
final class NoteRowView: NSView {
    private let note: Note
    private let onAction: () -> Void
    private var actionsStack: NSStackView!
    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            actionsStack.animator().alphaValue = hovering ? 1 : 0
            needsDisplay = true
        }
    }

    init(note: Note, compact: Bool, onAction: @escaping () -> Void) {
        self.note = note
        self.onAction = onAction
        super.init(frame: .zero)
        setup()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.cornerRadius = 6

        let titleLabel = NSTextField(labelWithString: note.title)
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let catLabel = NSTextField(labelWithString: note.categoryDisplay)
        catLabel.font = .systemFont(ofSize: 11)
        catLabel.textColor = .secondaryLabelColor
        catLabel.lineBreakMode = .byTruncatingTail
        catLabel.translatesAutoresizingMaskIntoConstraints = false

        let openBtn = makeIconButton("arrow.up.forward.app", tip: "Open with\u{2026}", action: #selector(openWith(_:)))
        let copyNoteBtn = makeIconButton("doc.on.doc", tip: "Copy note", action: #selector(copyNote))
        let copyPathBtn = makeIconButton("folder", tip: "Copy path", action: #selector(copyPath))
        let deleteBtn = makeIconButton("trash", tip: "Delete", action: #selector(confirmDelete))
        deleteBtn.contentTintColor = .systemRed

        let actions = NSStackView(views: [openBtn, copyNoteBtn, copyPathBtn, deleteBtn])
        actions.orientation = .horizontal
        actions.spacing = 6
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.alphaValue = 0 // revealed on hover
        actionsStack = actions

        addSubview(titleLabel)
        addSubview(catLabel)
        addSubview(actions)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 44),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),

            catLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            catLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    /// Track mouse enter/exit so the row can highlight and reveal its action buttons.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self
        ))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    /// Clicking the row body (anywhere the action buttons don't intercept) opens the
    /// note in its own view/edit window and dismisses the popover.
    override func mouseDown(with event: NSEvent) {
        NoteWindowController.show(note: note)
        onAction()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hovering
            ? NSColor.labelColor.withAlphaComponent(0.07).cgColor
            : NSColor.clear.cgColor
    }

    private func makeIconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        btn.imagePosition = .imageOnly
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.toolTip = tip
        return btn
    }

    /// Pop up a menu of ALL configured open-with actions so any destination is reachable,
    /// not just the default first entry (rule #10). The first item is also the one-click default.
    @objc private func openWith(_ sender: NSButton) {
        let actions = PreferencesManager.shared.openWithActions
        guard !actions.isEmpty else {
            ToastWindow.show(message: "No open-with action configured")
            return
        }
        let menu = NSMenu()
        for (index, action) in actions.enumerated() {
            let title = index == 0 ? "\(action.name) (default)" : action.name
            let item = NSMenuItem(title: title, action: #selector(runOpenWith(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    @objc private func runOpenWith(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? OpenWithAction else { return }
        let body = NoteStore.shared.body(of: note)
        OpenWithService.shared.run(action: action, note: note, body: body)
        onAction()
    }

    @objc private func copyNote() {
        let body = NoteStore.shared.body(of: note)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(body, forType: .string)
        ToastWindow.show(message: "Copied note")
    }

    @objc private func copyPath() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(note.url.path, forType: .string)
        ToastWindow.show(message: "Copied path")
    }

    @objc private func confirmDelete() {
        let alert = NSAlert()
        alert.messageText = "Delete \"\(note.title)\"?"
        alert.informativeText = "This permanently removes the file."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            _ = NoteStore.shared.delete(note)
        }
    }
}
