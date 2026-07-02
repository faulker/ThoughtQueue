import Cocoa

/// Floating capture panel near the cursor: editable text, a category picker, and a
/// new-vs-append target picker. Writes through NoteStore.
final class CapturePanel {
    static let shared = CapturePanel()

    private static let newCategoryTag = -1
    private static let uncategorizedTag = 0

    private var panel: NSPanel?
    private var textView: NSTextView?
    private var categoryPopup: NSPopUpButton?
    private var targetPopup: NSPopUpButton?

    /// Append targets shown in the target popup, parallel to popup item order (after "New Note").
    private var appendTargets: [Note] = []
    private var lastSelectedCategoryName: String?

    private init() {}

    /// Show the capture panel pre-filled with text (empty for a blank note).
    func show(with text: String) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.show(with: text) }
            return
        }
        present(text: text)
    }

    private func present(text: String) {
        panel?.close()

        let width: CGFloat = 420
        let height: CGFloat = 300

        let mouse = NSEvent.mouseLocation
        let origin = NSPoint(x: mouse.x - width / 2, y: mouse.y - height - 20)

        let newPanel = NSPanel(
            contentRect: NSRect(origin: origin, size: NSSize(width: width, height: height)),
            styleMask: [.titled, .closable, .nonactivatingPanel, .hudWindow],
            backing: .buffered,
            defer: false
        )
        newPanel.level = .floating
        newPanel.title = "Capture to ThoughtQueue"
        newPanel.isFloatingPanel = true
        newPanel.isReleasedWhenClosed = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: width, height: height))

        // Text area
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let tv = NSTextView()
        tv.string = text
        tv.font = PreferencesManager.shared.editorFont
        tv.isEditable = true
        tv.isRichText = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.textContainerInset = NSSize(width: 4, height: 4)
        tv.textContainer?.widthTracksTextView = true
        tv.autoresizingMask = [.width, .height]
        scrollView.documentView = tv
        self.textView = tv

        // Target picker (new note vs. append to existing)
        let tPopup = NSPopUpButton()
        tPopup.translatesAutoresizingMaskIntoConstraints = false
        tPopup.target = self
        tPopup.action = #selector(targetChanged(_:))
        self.targetPopup = tPopup

        // Category picker (only meaningful for new notes)
        let popup = NSPopUpButton()
        popup.translatesAutoresizingMaskIntoConstraints = false
        popup.target = self
        popup.action = #selector(categoryChanged(_:))
        self.categoryPopup = popup

        populateTargetPopup()
        populateCategoryPopup(selecting: nil)
        updateCategoryEnabled()

        let saveBtn = NSButton(title: "Save", target: self, action: #selector(save))
        saveBtn.bezelStyle = .rounded
        saveBtn.keyEquivalent = "\r"
        saveBtn.translatesAutoresizingMaskIntoConstraints = false

        let cancelBtn = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        cancelBtn.bezelStyle = .rounded
        cancelBtn.keyEquivalent = "\u{1b}"
        cancelBtn.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(tPopup)
        content.addSubview(popup)
        content.addSubview(saveBtn)
        content.addSubview(cancelBtn)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: tPopup.topAnchor, constant: -12),

            tPopup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            tPopup.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            tPopup.bottomAnchor.constraint(equalTo: popup.topAnchor, constant: -10),

            popup.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            popup.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            popup.widthAnchor.constraint(greaterThanOrEqualToConstant: 150),

            saveBtn.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            saveBtn.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            saveBtn.widthAnchor.constraint(equalToConstant: 70),

            cancelBtn.trailingAnchor.constraint(equalTo: saveBtn.leadingAnchor, constant: -8),
            cancelBtn.centerYAnchor.constraint(equalTo: popup.centerYAnchor),
            cancelBtn.widthAnchor.constraint(equalToConstant: 80),
        ])

        newPanel.contentView = content
        newPanel.makeKeyAndOrderFront(nil)
        newPanel.makeFirstResponder(tv)
        NSApp.activate(ignoringOtherApps: true)
        panel = newPanel
    }

    // MARK: - Target popup

    private func populateTargetPopup() {
        guard let popup = targetPopup else { return }
        popup.removeAllItems()
        popup.addItem(withTitle: "New Note")

        appendTargets = NoteStore.shared.allNotes()
        if !appendTargets.isEmpty {
            popup.menu?.addItem(NSMenuItem.separator())
            for note in appendTargets {
                let label = note.category == nil ? note.title : "\(note.categoryDisplay) / \(note.title)"
                popup.addItem(withTitle: "Append to \(label)")
            }
        }
        popup.selectItem(at: 0)
    }

    @objc private func targetChanged(_ sender: NSPopUpButton) {
        updateCategoryEnabled()
    }

    /// Category only applies to new notes; disable it when appending.
    private func updateCategoryEnabled() {
        let isNewNote = (targetPopup?.indexOfSelectedItem ?? 0) == 0
        categoryPopup?.isEnabled = isNewNote
    }

    /// The currently chosen append target, or nil if "New Note" is selected.
    private func selectedAppendTarget() -> Note? {
        guard let popup = targetPopup else { return nil }
        let idx = popup.indexOfSelectedItem
        guard idx > 0 else { return nil }
        // Items: 0 = New Note, 1 = separator, 2... = targets.
        let targetIndex = idx - 2
        guard targetIndex >= 0, targetIndex < appendTargets.count else { return nil }
        return appendTargets[targetIndex]
    }

    // MARK: - Category popup

    private func populateCategoryPopup(selecting name: String?) {
        guard let popup = categoryPopup else { return }
        popup.removeAllItems()

        popup.addItem(withTitle: Note.uncategorized)
        popup.menu?.items.last?.tag = Self.uncategorizedTag

        for cat in NoteStore.shared.categories() {
            popup.addItem(withTitle: cat)
            popup.menu?.items.last?.tag = 1
        }

        popup.menu?.addItem(NSMenuItem.separator())
        let newItem = NSMenuItem(title: "+ New Category\u{2026}", action: nil, keyEquivalent: "")
        newItem.tag = Self.newCategoryTag
        popup.menu?.addItem(newItem)

        if let name = name, name != Note.uncategorized {
            popup.selectItem(withTitle: name)
        } else {
            popup.selectItem(at: 0)
        }
        lastSelectedCategoryName = popup.titleOfSelectedItem
    }

    @objc private func categoryChanged(_ sender: NSPopUpButton) {
        let tag = sender.selectedItem?.tag ?? 0
        guard tag == Self.newCategoryTag else {
            lastSelectedCategoryName = sender.titleOfSelectedItem
            return
        }
        promptForNewCategory()
    }

    private func promptForNewCategory() {
        let alert = NSAlert()
        alert.messageText = "New Category"
        alert.informativeText = "Enter a name for the new category:"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        alert.accessoryView = input

        let runHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self else { return }
            let trimmed = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard response == .alertFirstButtonReturn, !trimmed.isEmpty else {
                if let last = self.lastSelectedCategoryName { self.categoryPopup?.selectItem(withTitle: last) }
                return
            }
            _ = NoteStore.shared.createCategory(trimmed)
            self.populateCategoryPopup(selecting: trimmed)
        }

        if let panel = panel {
            alert.beginSheetModal(for: panel, completionHandler: runHandler)
        } else {
            runHandler(alert.runModal())
        }
    }

    // MARK: - Save / Cancel

    @objc private func save() {
        guard let tv = textView else { return }
        let text = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        if let target = selectedAppendTarget() {
            if NoteStore.shared.append(to: target, text: text) {
                ToastWindow.show(message: "Appended to \(target.title)")
            } else {
                // Fallback: target vanished, create a new note instead.
                _ = NoteStore.shared.createNote(title: "", body: text, category: nil)
                ToastWindow.show(message: "Target missing; saved new note")
            }
        } else {
            let categoryTitle = categoryPopup?.titleOfSelectedItem
            let category = (categoryTitle == Note.uncategorized) ? nil : categoryTitle
            if let note = NoteStore.shared.createNote(title: "", body: text, category: category) {
                ToastWindow.show(message: "Captured!")
                AutoIntelService.shared.process(note: note, body: text)
            }
        }
        closeAndReset()
    }

    @objc private func cancel() {
        closeAndReset()
    }

    private func closeAndReset() {
        panel?.close()
        panel = nil
        textView = nil
        categoryPopup = nil
        targetPopup = nil
        appendTargets = []
    }
}
