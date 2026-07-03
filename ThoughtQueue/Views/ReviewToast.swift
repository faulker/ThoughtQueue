import Cocoa

/// A transient panel under the status item showing the auto-generated title + category,
/// with an Edit affordance and a user-set timeout. Accepting applies the rename/move;
/// dismissing leaves the note with its capture-time defaults.
final class ReviewToast: NSObject, NSComboBoxDelegate {
    static let shared = ReviewToast()

    private var panel: NSPanel?
    private var dismissWorkItem: DispatchWorkItem?
    private var note: Note?
    private var titleField: NSTextField?
    /// Editable combo box: lists existing categories to pick from, but still accepts a typed
    /// new one. Selecting a match reuses the folder instead of creating a near-duplicate.
    private var categoryField: NSComboBox?
    /// The configured auto-dismiss delay, retained so a deferred dismiss can reschedule.
    private var timeout: TimeInterval = 0
    /// True while the user is actively editing the title or category field, which suppresses
    /// the auto-dismiss so a half-typed title is never thrown away (fix #6).
    private var isEditingField = false

    /// Anchor point (status item button) so the toast can appear beneath the menu bar icon.
    weak var anchorButton: NSStatusBarButton?

    private override init() { super.init() }

    func show(note: Note, suggestedTitle: String, suggestedCategory: String, timeout: TimeInterval) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(note: note, suggestedTitle: suggestedTitle, suggestedCategory: suggestedCategory, timeout: timeout) }
            return
        }

        close()
        self.note = note
        self.timeout = timeout
        self.isEditingField = false

        let width: CGFloat = 320
        let height: CGFloat = 150

        let origin = anchorOrigin(width: width, height: height)
        let newPanel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.title = "Suggested Title & Category"
        newPanel.isFloatingPanel = true
        newPanel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        let titleLabel = NSTextField(labelWithString: "Title")
        titleLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        let tField = NSTextField(string: suggestedTitle)
        tField.translatesAutoresizingMaskIntoConstraints = false
        tField.delegate = self
        self.titleField = tField

        let catLabel = NSTextField(labelWithString: "Category")
        catLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        catLabel.textColor = .secondaryLabelColor
        catLabel.translatesAutoresizingMaskIntoConstraints = false

        let cField = NSComboBox()
        cField.translatesAutoresizingMaskIntoConstraints = false
        cField.completes = true
        cField.hasVerticalScroller = true
        // Offer every existing category (plus Uncategorized) so the user can reuse one.
        let existing = NoteStore.shared.categories()
        cField.addItems(withObjectValues: [Note.uncategorized] + existing)
        cField.stringValue = suggestedCategory
        // If the suggestion matches an existing category, highlight it in the list.
        if let idx = ([Note.uncategorized] + existing).firstIndex(where: {
            $0.localizedCaseInsensitiveCompare(suggestedCategory) == .orderedSame
        }) {
            cField.selectItem(at: idx)
        }
        cField.delegate = self
        self.categoryField = cField

        let acceptBtn = NSButton(title: "Apply", target: self, action: #selector(accept))
        acceptBtn.bezelStyle = .rounded
        acceptBtn.keyEquivalent = "\r"
        acceptBtn.translatesAutoresizingMaskIntoConstraints = false

        let dismissBtn = NSButton(title: "Keep Default", target: self, action: #selector(dismiss))
        dismissBtn.bezelStyle = .rounded
        dismissBtn.keyEquivalent = "\u{1b}"
        dismissBtn.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(titleLabel)
        content.addSubview(tField)
        content.addSubview(catLabel)
        content.addSubview(cField)
        content.addSubview(acceptBtn)
        content.addSubview(dismissBtn)

        NSLayoutConstraint.activate([
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            titleLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            tField.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 2),
            tField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            catLabel.topAnchor.constraint(equalTo: tField.bottomAnchor, constant: 8),
            catLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),

            cField.topAnchor.constraint(equalTo: catLabel.bottomAnchor, constant: 2),
            cField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            cField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),

            acceptBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            acceptBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            dismissBtn.trailingAnchor.constraint(equalTo: acceptBtn.leadingAnchor, constant: -8),
            dismissBtn.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
        ])

        newPanel.contentView = content
        newPanel.orderFront(nil)
        panel = newPanel

        scheduleDismiss()
    }

    /// Arm the auto-dismiss timer (treated as "keep default"). If the user is mid-edit when it
    /// fires, it re-arms instead of dismissing, so an in-progress title/category isn't lost.
    private func scheduleDismiss() {
        dismissWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self = self else { return }
            if self.isEditingField {
                self.scheduleDismiss() // still typing: check again after another interval
            } else {
                self.dismiss()
            }
        }
        dismissWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout, execute: item)
    }

    // MARK: - Editing state (suppresses auto-dismiss while focused)

    func controlTextDidBeginEditing(_ obj: Notification) { isEditingField = true }

    func controlTextDidEndEditing(_ obj: Notification) {
        isEditingField = false
        scheduleDismiss() // resume the countdown once focus leaves the field
    }

    // Opening the category dropdown counts as interaction: suppress auto-dismiss until it
    // closes so the toast can't vanish while the user is browsing existing categories.
    func comboBoxWillPopUp(_ notification: Notification) {
        isEditingField = true
        dismissWorkItem?.cancel()
    }

    func comboBoxWillDismiss(_ notification: Notification) {
        isEditingField = false
        scheduleDismiss()
    }

    private func anchorOrigin(width: CGFloat, height: CGFloat) -> NSPoint {
        if let button = anchorButton, let window = button.window {
            let buttonFrame = button.convert(button.bounds, to: nil)
            let screenRect = window.convertToScreen(buttonFrame)
            return NSPoint(x: screenRect.midX - width / 2, y: screenRect.minY - height - 8)
        }
        // Fallback: top-right of the main screen.
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        return NSPoint(x: screen.maxX - width - 20, y: screen.maxY - height - 20)
    }

    @objc private func accept() {
        guard let note = note else { close(); return }
        let title = titleField?.stringValue ?? note.title
        let category = categoryField?.stringValue ?? note.categoryDisplay
        _ = AutoIntelService.shared.apply(title: title, category: category, to: note)
        ToastWindow.show(message: "Updated")
        close()
    }

    @objc private func dismiss() {
        close()
    }

    private func close() {
        dismissWorkItem?.cancel()
        dismissWorkItem = nil
        isEditingField = false
        panel?.close()
        panel = nil
        note = nil
        titleField = nil
        categoryField = nil
    }
}
