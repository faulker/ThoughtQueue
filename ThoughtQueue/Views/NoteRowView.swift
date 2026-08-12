import Cocoa

/// A single note row used in the popover. Shows the title + category and offers quick
/// actions: open-with, clone, copy note, copy path, and delete. Deleting confirms inline,
/// inside the row itself, rather than throwing a modal dialog over the menu bar.
final class NoteRowView: NSView {
    /// How long the inline "Delete?" prompt stays up before it cancels itself.
    private static let confirmTimeout: TimeInterval = 5

    private let note: Note
    private let onAction: () -> Void
    private var actionsStack: NSStackView!
    private var confirmStack: NSStackView!
    private var pendingCancel: DispatchWorkItem?

    /// True while the row is showing its inline delete confirmation.
    private(set) var isConfirmingDelete = false {
        didSet {
            guard isConfirmingDelete != oldValue else { return }
            actionsStack.isHidden = isConfirmingDelete
            confirmStack.isHidden = !isConfirmingDelete
            updateActionAlpha()
        }
    }

    private var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            updateActionAlpha()
            // Moving off the row abandons a pending confirmation rather than leaving it armed.
            if !hovering { cancelDelete() }
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
        layer?.cornerRadius = Theme.radiusRow

        let titleLabel = NSTextField(labelWithString: note.title)
        titleLabel.font = Theme.body(12.5, weight: .semibold)
        titleLabel.textColor = Theme.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let catLabel = NSTextField(labelWithString: note.categoryDisplay)
        catLabel.font = Theme.body(10, weight: .semibold)
        catLabel.textColor = Theme.accentBorder
        catLabel.lineBreakMode = .byTruncatingTail
        catLabel.translatesAutoresizingMaskIntoConstraints = false

        let openBtn = makeIconButton("arrow.up.forward.app", tip: "Open with\u{2026}", action: #selector(openWith(_:)))
        let cloneBtn = makeIconButton("plus.square.on.square", tip: "Clone note", action: #selector(cloneNote))
        let copyNoteBtn = makeIconButton("doc.on.doc", tip: "Copy note", action: #selector(copyNote))
        let copyPathBtn = makeIconButton("folder", tip: "Copy path", action: #selector(copyPath))
        let deleteBtn = makeIconButton("trash", tip: "Delete", action: #selector(confirmDelete))
        deleteBtn.contentTintColor = Theme.danger

        let actions = NSStackView(views: [openBtn, cloneBtn, copyNoteBtn, copyPathBtn, deleteBtn])
        actions.orientation = .horizontal
        actions.spacing = 2
        actions.translatesAutoresizingMaskIntoConstraints = false
        actions.alphaValue = 0 // revealed on hover
        actionsStack = actions

        // The inline delete confirmation: takes the action strip's place in the row instead of
        // opening a modal alert, which would pull focus away from the menu bar popover.
        let confirmLabel = NSTextField(labelWithString: "Delete?")
        confirmLabel.font = Theme.body(11, weight: .semibold)
        confirmLabel.textColor = Theme.danger
        let confirmBtn = makeIconButton("checkmark.circle.fill", tip: "Confirm delete", action: #selector(performDelete))
        confirmBtn.contentTintColor = Theme.danger
        let cancelBtn = makeIconButton("xmark.circle", tip: "Cancel", action: #selector(cancelDeleteAction))

        let confirm = NSStackView(views: [confirmLabel, confirmBtn, cancelBtn])
        confirm.orientation = .horizontal
        confirm.spacing = 2
        confirm.translatesAutoresizingMaskIntoConstraints = false
        confirm.alphaValue = 0
        confirm.isHidden = true
        confirmStack = confirm

        addSubview(titleLabel)
        addSubview(catLabel)
        addSubview(actions)
        addSubview(confirm)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: Theme.metric(44)),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: actions.leadingAnchor, constant: -8),

            catLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            catLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),

            actions.centerYAnchor.constraint(equalTo: centerYAnchor),
            actions.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),

            confirm.centerYAnchor.constraint(equalTo: centerYAnchor),
            confirm.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
        ])
    }

    deinit { pendingCancel?.cancel() }

    /// Reveal whichever strip is current (actions, or the delete confirmation) on hover. The
    /// confirmation stays visible regardless so it can't be armed invisibly.
    private func updateActionAlpha() {
        actionsStack.animator().alphaValue = (hovering && !isConfirmingDelete) ? 1 : 0
        confirmStack.animator().alphaValue = isConfirmingDelete ? 1 : 0
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

    /// Recompute hover directly from the current mouse position. AppKit only updates tracking
    /// areas on actual mouse movement, so scrolling a row out from under a stationary cursor
    /// never fires `mouseExited` on its own — the popover calls this on every scroll tick to
    /// clear hover state that would otherwise stay stuck.
    func refreshHoverState() {
        guard let window else { hovering = false; return }
        let mouseInView = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        hovering = bounds.contains(mouseInView)
    }

    /// Clicking the row body (anywhere the action buttons don't intercept) opens the
    /// note in its own view/edit window and dismisses the popover. Close the popover
    /// first so dismissal does not steal activation back from the note window.
    override func mouseDown(with event: NSEvent) {
        // While the delete confirmation is up, a click on the row body means "never mind",
        // not "open this note".
        if isConfirmingDelete {
            cancelDelete()
            return
        }
        onAction()
        NoteWindowController.show(note: note)
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = hovering ? Theme.hoverRow.cgColor : NSColor.clear.cgColor
    }

    /// Build an action button whose clickable area is a padded 28×28 box centered on the icon,
    /// not just the glyph itself. The extra padding means a click landing a few pixels off the
    /// icon still triggers the button instead of falling through to the row's open action.
    private func makeIconButton(_ symbol: String, tip: String, action: Selector) -> NSButton {
        let btn = NSButton(title: "", target: self, action: action)
        btn.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.contentTintColor = Theme.iconStroke
        btn.toolTip = tip
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 28),
            btn.heightAnchor.constraint(equalToConstant: 28),
        ])
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

    /// Duplicate this note with title `copy <parent title>`, same body and category.
    @objc private func cloneNote() {
        guard NoteStore.shared.clone(note) != nil else {
            ToastWindow.show(message: "Clone failed")
            return
        }
        ToastWindow.show(message: "Cloned note")
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

    /// First trash click: arm the inline confirmation and start its auto-cancel timer.
    @objc func confirmDelete() {
        isConfirmingDelete = true
        pendingCancel?.cancel()
        let timeout = DispatchWorkItem { [weak self] in self?.cancelDelete() }
        pendingCancel = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.confirmTimeout, execute: timeout)
    }

    /// Second click, on the checkmark: the note is gone for good.
    @objc func performDelete() {
        pendingCancel?.cancel()
        pendingCancel = nil
        isConfirmingDelete = false
        if !NoteStore.shared.delete(note) {
            ToastWindow.show(message: "Delete failed")
        }
    }

    @objc private func cancelDeleteAction() { cancelDelete() }

    /// Drop a pending confirmation and return the row to its normal action strip.
    func cancelDelete() {
        guard isConfirmingDelete else { return }
        pendingCancel?.cancel()
        pendingCancel = nil
        isConfirmingDelete = false
    }
}
