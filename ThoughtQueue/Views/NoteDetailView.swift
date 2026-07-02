import Cocoa

/// An NSTextView that, while read-only (rendered markdown), switches into edit mode on
/// the first click instead of just selecting text.
final class ClickToEditTextView: NSTextView {
    var onActivateEditing: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if !isEditable, let activate = onActivateEditing {
            activate()
            // Now editable + first responder; forward the click so the cursor lands here.
            super.mouseDown(with: event)
        } else {
            super.mouseDown(with: event)
        }
    }
}

/// Detail pane for a single note. Honors the click-behavior preference: run the default
/// open-with command, render markdown read-only, or edit the raw markdown in place.
/// Clicking the rendered markdown switches into raw edit mode.
final class NoteDetailViewController: NSViewController, NSTextViewDelegate {
    private var note: Note?

    private var scrollView: NSScrollView!
    private var textView: ClickToEditTextView!
    private var headerLabel: NSTextField!
    private var openWithButton: NSButton!
    private var isEditing = false
    /// True when the raw text has unsaved changes since the last save/load.
    private var isDirty = false

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: 550))

        headerLabel = NSTextField(labelWithString: "")
        headerLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        headerLabel.lineBreakMode = .byTruncatingTail
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(headerLabel)

        openWithButton = NSButton(title: "Open With\u{2026}", target: self, action: #selector(openWith(_:)))
        openWithButton.bezelStyle = .rounded
        openWithButton.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(openWithButton)

        scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        textView = ClickToEditTextView()
        textView.delegate = self
        textView.onActivateEditing = { [weak self] in self?.beginEditing() }
        textView.font = PreferencesManager.shared.editorFont
        textView.isRichText = false
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.textContainer?.widthTracksTextView = true
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView
        container.addSubview(scrollView)

        NSLayoutConstraint.activate([
            headerLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 12),
            headerLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            headerLabel.trailingAnchor.constraint(lessThanOrEqualTo: openWithButton.leadingAnchor, constant: -8),

            openWithButton.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            openWithButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: headerLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -12),
        ])

        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onEditorFontChanged), name: .editorFontDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    /// Re-apply the new font: update the editor and re-render the current note if shown.
    @objc private func onEditorFontChanged() {
        textView.font = PreferencesManager.shared.editorFont
        guard let note = note else { return }
        if isEditing {
            // Raw text already picks up textView.font; nothing else to do.
        } else {
            renderMarkdown(note)
        }
    }

    /// Show a note according to the configured click behavior.
    func display(_ note: Note) {
        _ = view
        saveIfDirty()   // flush any pending edits on the note we're leaving
        self.note = note
        headerLabel.stringValue = note.category == nil ? note.title : "\(note.categoryDisplay) / \(note.title)"

        switch PreferencesManager.shared.clickBehavior {
        case .openCommand:
            renderMarkdown(note)        // show something while the command runs
            runOpenCommand(note)
        case .renderMarkdown:
            renderMarkdown(note)
        case .editRaw:
            editRaw(note)
        }
    }

    private func renderMarkdown(_ note: Note) {
        isEditing = false
        isDirty = false
        textView.isEditable = false
        let body = NoteStore.shared.body(of: note)
        // Block-level rendering: headings, lists, and task checkboxes (rule #12).
        let attributed = MarkdownRenderer.render(body, baseFont: PreferencesManager.shared.editorFont)
        textView.textStorage?.setAttributedString(attributed)
    }

    private func editRaw(_ note: Note) {
        isEditing = true
        isDirty = false
        textView.isEditable = true
        // Pin the editor font: setting `string` adopts the current typing attributes, which
        // after a markdown render carry whatever (possibly larger heading) font sat at the
        // cursor. Reset typing attributes and reapply the font so raw text stays consistent.
        let font = PreferencesManager.shared.editorFont
        textView.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]
        textView.string = NoteStore.shared.body(of: note)
        textView.font = font
    }

    /// Show a note and immediately drop into raw edit mode (used for freshly created notes).
    func displayForEditing(_ note: Note) {
        _ = view
        saveIfDirty()   // flush any pending edits on the note we're leaving
        self.note = note
        headerLabel.stringValue = note.category == nil ? note.title : "\(note.categoryDisplay) / \(note.title)"
        beginEditing()
    }

    /// Switch the currently displayed note from rendered markdown into raw edit mode.
    private func beginEditing() {
        guard let note = note, !isEditing else { return }
        editRaw(note)
        view.window?.makeFirstResponder(textView)
    }

    private func runOpenCommand(_ note: Note) {
        guard let action = PreferencesManager.shared.defaultOpenWithAction else { return }
        let body = NoteStore.shared.body(of: note)
        OpenWithService.shared.run(action: action, note: note, body: body)
    }

    /// Per-note destination picker listing ALL configured open-with actions (rule #10).
    @objc private func openWith(_ sender: NSButton) {
        guard let note = note else { return }
        let actions = PreferencesManager.shared.openWithActions
        guard !actions.isEmpty else {
            ToastWindow.show(message: "No open-with action configured")
            return
        }
        let menu = NSMenu()
        for (index, action) in actions.enumerated() {
            let title = index == 0 ? "\(action.name) (default)" : action.name
            let item = NSMenuItem(title: title, action: #selector(runPickedAction(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action
            menu.addItem(item)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
        _ = note
    }

    @objc private func runPickedAction(_ sender: NSMenuItem) {
        guard let note = note, let action = sender.representedObject as? OpenWithAction else { return }
        let body = NoteStore.shared.body(of: note)
        OpenWithService.shared.run(action: action, note: note, body: body)
    }

    // MARK: - Autosave

    /// Track edits so we only write to disk when something actually changed.
    func textDidChange(_ notification: Notification) {
        if isEditing { isDirty = true }
    }

    /// Fired when the text view resigns first responder (the user clicked away,
    /// switched windows, or closed the window). Persist the edit on focus loss.
    func textDidEndEditing(_ notification: Notification) {
        saveIfDirty()
    }

    /// Flush before the detail view goes away (e.g. the window closes) in case
    /// focus loss didn't already trigger a save.
    override func viewWillDisappear() {
        super.viewWillDisappear()
        saveIfDirty()
    }

    /// Persist the current raw text if we're editing and have unsaved changes.
    private func saveIfDirty() {
        guard isEditing, isDirty, let note = note else { return }
        _ = NoteStore.shared.updateBody(of: note, body: textView.string)
        isDirty = false
        ToastWindow.show(message: "Saved")
    }
}
