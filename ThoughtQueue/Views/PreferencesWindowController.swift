import Cocoa
import UniformTypeIdentifiers

/// Wraps a closure so it can be a target/action for an NSButton. Hold a strong reference
/// for the button's lifetime (NSButton.target is weak).
private final class ActionTrampoline: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func fire() { handler() }
}

/// Settings: store-location chooser, working document, click behavior, open-with editor,
/// hotkeys, toast timeout, auto-intel toggle, start-at-login.
final class PreferencesWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate {
    static let shared = PreferencesWindowController()

    private let quickRecorder = ShortcutRecorderView()
    private let detailedRecorder = ShortcutRecorderView()
    private let startAtLoginCheckbox = NSButton(checkboxWithTitle: "Start ThoughtQueue at login", target: nil, action: nil)
    private let autoIntelCheckbox = NSButton(checkboxWithTitle: "Auto title & categorize (on-device)", target: nil, action: nil)
    private let storePathLabel = NSTextField(labelWithString: "")
    private let clickBehaviorPopup = NSPopUpButton()
    private let noteEditModePopup = NSPopUpButton()
    private let editorFontLabel = NSTextField(labelWithString: "")
    private let timeoutField = NSTextField()
    private let openWithTable = NSTableView()

    private var openWithActions: [OpenWithAction] = []

    convenience init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 620),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "ThoughtQueue Preferences"
        window.center()
        self.init(window: window)
        openWithActions = PreferencesManager.shared.openWithActions
        setupUI()
    }

    private func setupUI() {
        guard let content = window?.contentView else { return }

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -20),
        ])

        // Store location
        stack.addArrangedSubview(sectionLabel("Store Folder"))
        storePathLabel.stringValue = PreferencesManager.shared.storeURL?.path ?? "(not set)"
        storePathLabel.font = .systemFont(ofSize: 12)
        storePathLabel.textColor = .secondaryLabelColor
        storePathLabel.lineBreakMode = .byTruncatingMiddle
        let chooseBtn = NSButton(title: "Choose\u{2026}", target: self, action: #selector(chooseStore))
        chooseBtn.bezelStyle = .rounded
        stack.addArrangedSubview(row([storePathLabel, chooseBtn]))

        // Click behavior
        stack.addArrangedSubview(sectionLabel("When clicking a note"))
        clickBehaviorPopup.addItems(withTitles: ["Render markdown", "Edit raw", "Run open command"])
        clickBehaviorPopup.target = self
        clickBehaviorPopup.action = #selector(clickBehaviorChanged)
        selectClickBehavior()
        stack.addArrangedSubview(clickBehaviorPopup)

        // Note editor edit-mode behavior
        stack.addArrangedSubview(sectionLabel("When opening a note"))
        noteEditModePopup.addItems(withTitles: ["Double-click to edit", "Single click to edit", "Always in edit mode"])
        noteEditModePopup.target = self
        noteEditModePopup.action = #selector(noteEditModeChanged)
        selectNoteEditMode()
        stack.addArrangedSubview(noteEditModePopup)

        // Note editor font
        stack.addArrangedSubview(sectionLabel("Note editor font"))
        editorFontLabel.font = .systemFont(ofSize: 12)
        editorFontLabel.textColor = .secondaryLabelColor
        editorFontLabel.lineBreakMode = .byTruncatingMiddle
        updateEditorFontLabel()
        let selectFontBtn = NSButton(title: "Select Font\u{2026}", target: self, action: #selector(selectFont))
        selectFontBtn.bezelStyle = .rounded
        let resetFontBtn = NSButton(title: "Reset", target: self, action: #selector(resetFont))
        resetFontBtn.bezelStyle = .rounded
        stack.addArrangedSubview(row([editorFontLabel, selectFontBtn, resetFontBtn]))

        // Hotkeys
        stack.addArrangedSubview(sectionLabel("Hotkeys (restart to apply)"))
        quickRecorder.translatesAutoresizingMaskIntoConstraints = false
        detailedRecorder.translatesAutoresizingMaskIntoConstraints = false
        quickRecorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
        quickRecorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
        detailedRecorder.widthAnchor.constraint(equalToConstant: 180).isActive = true
        detailedRecorder.heightAnchor.constraint(equalToConstant: 24).isActive = true
        quickRecorder.keyBinding = PreferencesManager.shared.quickCaptureKey
        detailedRecorder.keyBinding = PreferencesManager.shared.detailedCaptureKey
        quickRecorder.onChanged = { PreferencesManager.shared.quickCaptureKey = $0 }
        detailedRecorder.onChanged = { PreferencesManager.shared.detailedCaptureKey = $0 }
        stack.addArrangedSubview(row([fixedLabel("Quick Capture:", 140), quickRecorder]))
        stack.addArrangedSubview(row([fixedLabel("Detailed Capture:", 140), detailedRecorder]))

        // Toast timeout
        stack.addArrangedSubview(sectionLabel("Review toast timeout (seconds)"))
        timeoutField.stringValue = String(Int(PreferencesManager.shared.toastTimeout))
        timeoutField.translatesAutoresizingMaskIntoConstraints = false
        timeoutField.widthAnchor.constraint(equalToConstant: 60).isActive = true
        timeoutField.target = self
        timeoutField.action = #selector(timeoutChanged)
        stack.addArrangedSubview(timeoutField)

        // Open-with editor
        stack.addArrangedSubview(sectionLabel("Open With actions"))
        let owScroll = NSScrollView()
        owScroll.translatesAutoresizingMaskIntoConstraints = false
        owScroll.hasVerticalScroller = true
        owScroll.borderType = .bezelBorder
        owScroll.documentView = openWithTable
        owScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        owScroll.widthAnchor.constraint(equalToConstant: 470).isActive = true
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("ow"))
        openWithTable.addTableColumn(col)
        openWithTable.headerView = nil
        openWithTable.delegate = self
        openWithTable.dataSource = self
        stack.addArrangedSubview(owScroll)
        let addOWBtn = NSButton(title: "Add\u{2026}", target: self, action: #selector(addOpenWith))
        addOWBtn.bezelStyle = .rounded
        let editOWBtn = NSButton(title: "Edit\u{2026}", target: self, action: #selector(editOpenWith))
        editOWBtn.bezelStyle = .rounded
        let deleteOWBtn = NSButton(title: "Delete", target: self, action: #selector(deleteOpenWith))
        deleteOWBtn.bezelStyle = .rounded
        let resetOWBtn = NSButton(title: "Reset defaults", target: self, action: #selector(resetOpenWith))
        resetOWBtn.bezelStyle = .rounded
        stack.addArrangedSubview(row([addOWBtn, editOWBtn, deleteOWBtn, resetOWBtn]))

        // Toggles
        autoIntelCheckbox.state = PreferencesManager.shared.autoIntelEnabled ? .on : .off
        autoIntelCheckbox.target = self
        autoIntelCheckbox.action = #selector(autoIntelToggled)
        stack.addArrangedSubview(autoIntelCheckbox)

        startAtLoginCheckbox.state = PreferencesManager.shared.startAtLogin ? .on : .off
        startAtLoginCheckbox.target = self
        startAtLoginCheckbox.action = #selector(startAtLoginToggled)
        stack.addArrangedSubview(startAtLoginCheckbox)
    }

    // MARK: - Layout helpers

    private func sectionLabel(_ text: String) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13, weight: .semibold)
        return l
    }

    private func fixedLabel(_ text: String, _ width: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = .systemFont(ofSize: 13)
        l.translatesAutoresizingMaskIntoConstraints = false
        l.widthAnchor.constraint(equalToConstant: width).isActive = true
        return l
    }

    private func row(_ views: [NSView]) -> NSStackView {
        let s = NSStackView(views: views)
        s.orientation = .horizontal
        s.spacing = 8
        return s
    }

    private func selectClickBehavior() {
        switch PreferencesManager.shared.clickBehavior {
        case .renderMarkdown: clickBehaviorPopup.selectItem(at: 0)
        case .editRaw: clickBehaviorPopup.selectItem(at: 1)
        case .openCommand: clickBehaviorPopup.selectItem(at: 2)
        }
    }

    private func selectNoteEditMode() {
        switch PreferencesManager.shared.noteEditMode {
        case .doubleClick: noteEditModePopup.selectItem(at: 0)
        case .singleClick: noteEditModePopup.selectItem(at: 1)
        case .alwaysEdit: noteEditModePopup.selectItem(at: 2)
        }
    }

    // MARK: - Actions

    @objc private func chooseStore() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.directoryURL = PreferencesManager.shared.storeURL ?? PreferencesManager.shared.defaultStoreURL
        if panel.runModal() == .OK, let url = panel.url {
            PreferencesManager.shared.storeURL = url
            NoteStore.shared.rootURL = url
            storePathLabel.stringValue = url.path
            (NSApp.delegate as? AppDelegate)?.restartWatcher()
            NotificationCenter.default.post(name: .notesDidChange, object: nil)
        }
    }

    @objc private func clickBehaviorChanged() {
        switch clickBehaviorPopup.indexOfSelectedItem {
        case 0: PreferencesManager.shared.clickBehavior = .renderMarkdown
        case 1: PreferencesManager.shared.clickBehavior = .editRaw
        default: PreferencesManager.shared.clickBehavior = .openCommand
        }
    }

    @objc private func noteEditModeChanged() {
        switch noteEditModePopup.indexOfSelectedItem {
        case 0: PreferencesManager.shared.noteEditMode = .doubleClick
        case 1: PreferencesManager.shared.noteEditMode = .singleClick
        default: PreferencesManager.shared.noteEditMode = .alwaysEdit
        }
    }

    @objc private func timeoutChanged() {
        if let v = Double(timeoutField.stringValue), v > 0 {
            PreferencesManager.shared.toastTimeout = v
        }
    }

    // MARK: - Editor font

    private func updateEditorFontLabel() {
        let font = PreferencesManager.shared.editorFont
        editorFontLabel.stringValue = "\(font.displayName ?? font.fontName), \(Int(font.pointSize)) pt"
    }

    /// Open the system font panel seeded with the current editor font.
    @objc private func selectFont() {
        let fm = NSFontManager.shared
        fm.target = self
        fm.action = #selector(changeFont(_:))
        fm.setSelectedFont(PreferencesManager.shared.editorFont, isMultiple: false)
        fm.orderFrontFontPanel(self)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Font panel callback: convert the current font through the panel and persist it.
    @objc func changeFont(_ sender: NSFontManager?) {
        guard let fm = sender else { return }
        let newFont = fm.convert(PreferencesManager.shared.editorFont)
        PreferencesManager.shared.editorFont = newFont
        updateEditorFontLabel()
    }

    @objc private func resetFont() {
        PreferencesManager.shared.editorFont = .systemFont(ofSize: PreferencesManager.defaultEditorFontSize)
        updateEditorFontLabel()
    }

    @objc private func autoIntelToggled(_ sender: NSButton) {
        PreferencesManager.shared.autoIntelEnabled = sender.state == .on
    }

    @objc private func startAtLoginToggled(_ sender: NSButton) {
        PreferencesManager.shared.startAtLogin = sender.state == .on
    }

    @objc private func resetOpenWith() {
        openWithActions = OpenWithAction.presets
        PreferencesManager.shared.openWithActions = openWithActions
        openWithTable.reloadData()
    }

    @objc private func addOpenWith() {
        presentOpenWithEditor(existing: nil)
    }

    @objc private func editOpenWith() {
        let row = openWithTable.selectedRow
        guard row >= 0, row < openWithActions.count else {
            ToastWindow.show(message: "Select an action to edit")
            return
        }
        presentOpenWithEditor(existing: row)
    }

    @objc private func deleteOpenWith() {
        let row = openWithTable.selectedRow
        guard row >= 0, row < openWithActions.count else {
            ToastWindow.show(message: "Select an action to delete")
            return
        }
        openWithActions.remove(at: row)
        PreferencesManager.shared.openWithActions = openWithActions
        openWithTable.reloadData()
    }

    /// Modal editor for an open-with action. `existing` is the row index to edit, or nil to add.
    /// Persists via the Codable model (rule #11).
    private func presentOpenWithEditor(existing: Int?) {
        let editing = existing.map { openWithActions[$0] }

        let alert = NSAlert()
        alert.messageText = existing == nil ? "Add Open With Action" : "Edit Open With Action"
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let width: CGFloat = 440
        let fieldX: CGFloat = 95
        let browseW: CGFloat = 86
        let fieldW = width - fieldX - browseW - 8
        let accessory = NSView(frame: NSRect(x: 0, y: 0, width: width, height: 130))

        let nameField = NSTextField(frame: NSRect(x: fieldX, y: 102, width: width - fieldX, height: 24))
        nameField.placeholderString = "Name (e.g. Zed)"
        nameField.stringValue = editing?.name ?? ""
        accessory.addSubview(label("Name:", y: 104))
        accessory.addSubview(nameField)

        // "Method" describes how THIS destination delivers a note; it is a property of the
        // destination, not of any note. Picking a method swaps the row below in place.
        let typePopup = NSPopUpButton(frame: NSRect(x: fieldX, y: 70, width: 200, height: 24))
        typePopup.addItems(withTitles: ["Run a command", "Send to an app"])
        typePopup.selectItem(at: (editing?.type ?? .command) == .appInput ? 1 : 0)
        accessory.addSubview(label("Method:", y: 72))
        accessory.addSubview(typePopup)

        // Command and App share the same row; only one is shown for the selected method.
        let commandLabel = label("Command:", y: 40)
        let templateField = NSTextField(frame: NSRect(x: fieldX, y: 38, width: fieldW, height: 24))
        templateField.placeholderString = "Command, e.g. zed {path}"
        templateField.stringValue = editing?.commandTemplate ?? ""
        accessory.addSubview(commandLabel)
        accessory.addSubview(templateField)

        let appLabel = label("App:", y: 40)
        let bundleField = NSTextField(frame: NSRect(x: fieldX, y: 38, width: fieldW, height: 24))
        bundleField.placeholderString = "App bundle id"
        bundleField.stringValue = editing?.appBundleId ?? ""
        accessory.addSubview(appLabel)
        accessory.addSubview(bundleField)

        let inputLabel = label("Input:", y: 8)
        let modePopup = NSPopUpButton(frame: NSRect(x: fieldX, y: 6, width: 200, height: 24))
        modePopup.addItems(withTitles: ["File reference (@path)", "Paste contents"])
        modePopup.selectItem(at: (editing?.inputMode ?? .reference) == .body ? 1 : 0)
        accessory.addSubview(inputLabel)
        accessory.addSubview(modePopup)

        // Browse for a command: pick an executable or .app and build the command template.
        let browseCommand = ActionTrampoline {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.treatsFilePackagesAsDirectories = false
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            templateField.stringValue = OpenWithService.commandTemplate(forChosenURL: url)
            if nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nameField.stringValue = url.deletingPathExtension().lastPathComponent
            }
        }
        let browseCommandBtn = NSButton(title: "Browse\u{2026}", target: browseCommand, action: #selector(ActionTrampoline.fire))
        browseCommandBtn.bezelStyle = .rounded
        browseCommandBtn.frame = NSRect(x: width - browseW, y: 37, width: browseW, height: 26)
        accessory.addSubview(browseCommandBtn)

        // Browse for an app: pick a .app and derive its bundle id automatically.
        let chooseApp = ActionTrampoline {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.application]
            panel.directoryURL = URL(fileURLWithPath: "/Applications")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            if let bundleId = Bundle(url: url)?.bundleIdentifier {
                bundleField.stringValue = bundleId
            }
            if nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                nameField.stringValue = url.deletingPathExtension().lastPathComponent
            }
        }
        let chooseAppBtn = NSButton(title: "Choose App\u{2026}", target: chooseApp, action: #selector(ActionTrampoline.fire))
        chooseAppBtn.bezelStyle = .rounded
        chooseAppBtn.frame = NSRect(x: width - browseW, y: 37, width: browseW, height: 26)
        accessory.addSubview(chooseAppBtn)

        // Show only the fields relevant to the selected method.
        let commandViews: [NSView] = [commandLabel, templateField, browseCommandBtn]
        let appViews: [NSView] = [appLabel, bundleField, chooseAppBtn, inputLabel, modePopup]
        let applyMethodVisibility = ActionTrampoline {
            let isApp = typePopup.indexOfSelectedItem == 1
            commandViews.forEach { $0.isHidden = isApp }
            appViews.forEach { $0.isHidden = !isApp }
        }
        typePopup.target = applyMethodVisibility
        typePopup.action = #selector(ActionTrampoline.fire)
        applyMethodVisibility.fire() // set initial state

        alert.accessoryView = accessory

        let response: NSApplication.ModalResponse
        if let window = window {
            // Synchronous modal sheet for simplicity.
            response = alert.runModal()
            _ = window
        } else {
            response = alert.runModal()
        }
        // Keep the trampolines alive until the modal closes.
        _ = (browseCommand, chooseApp, applyMethodVisibility)
        guard response == .alertFirstButtonReturn else { return }

        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { ToastWindow.show(message: "Name is required"); return }

        let type: OpenWithType = typePopup.indexOfSelectedItem == 1 ? .appInput : .command
        var action = editing ?? OpenWithAction(name: name, type: type)
        action.name = name
        action.type = type
        if type == .command {
            action.commandTemplate = templateField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            action.appBundleId = nil
            action.inputMode = nil
        } else {
            action.appBundleId = bundleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            action.inputMode = modePopup.indexOfSelectedItem == 1 ? .body : .reference
            action.commandTemplate = nil
        }

        if let row = existing {
            openWithActions[row] = action
        } else {
            openWithActions.append(action)
        }
        PreferencesManager.shared.openWithActions = openWithActions
        openWithTable.reloadData()
    }

    private func label(_ text: String, y: CGFloat) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.frame = NSRect(x: 0, y: y, width: 85, height: 20)
        l.alignment = .right
        l.font = .systemFont(ofSize: 12)
        return l
    }

    // MARK: - Open-with table

    func numberOfRows(in tableView: NSTableView) -> Int { openWithActions.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let a = openWithActions[row]
        let detail: String
        switch a.type {
        case .command: detail = a.commandTemplate ?? ""
        case .appInput: detail = "\(a.appBundleId ?? "") [\(a.inputMode?.rawValue ?? "reference")]"
        }
        let label = NSTextField(labelWithString: "\(a.name) — \(detail)")
        label.font = .systemFont(ofSize: 12)
        label.lineBreakMode = .byTruncatingTail
        return label
    }
}

// MARK: - Shortcut Recorder

final class ShortcutRecorderView: NSView {
    var keyBinding: KeyBinding = .defaultQuickCapture { didSet { updateDisplay() } }
    var onChanged: ((KeyBinding) -> Void)?

    private let label = NSTextField(labelWithString: "")
    private var isRecording = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        setup()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func setup() {
        wantsLayer = true
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.cornerRadius = 4
        label.font = .systemFont(ofSize: 12)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        updateDisplay()
    }

    private func updateDisplay() {
        if isRecording {
            label.stringValue = "Press shortcut\u{2026}"
            layer?.borderColor = NSColor.controlAccentColor.cgColor
        } else {
            label.stringValue = describe(keyBinding)
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }

    override func mouseDown(with event: NSEvent) {
        isRecording = true
        updateDisplay()
        window?.makeFirstResponder(self)
    }

    override var acceptsFirstResponder: Bool { true }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        guard !flags.isEmpty else { return }
        var cgFlags = CGEventFlags()
        if flags.contains(.command) { cgFlags.insert(.maskCommand) }
        if flags.contains(.shift) { cgFlags.insert(.maskShift) }
        if flags.contains(.option) { cgFlags.insert(.maskAlternate) }
        if flags.contains(.control) { cgFlags.insert(.maskControl) }
        let binding = KeyBinding(keyCode: Int64(event.keyCode), modifiers: cgFlags)
        keyBinding = binding
        isRecording = false
        updateDisplay()
        onChanged?(binding)
    }

    private func describe(_ binding: KeyBinding) -> String {
        var parts: [String] = []
        if binding.modifiers.contains(.maskControl) { parts.append("\u{2303}") }
        if binding.modifiers.contains(.maskAlternate) { parts.append("\u{2325}") }
        if binding.modifiers.contains(.maskShift) { parts.append("\u{21E7}") }
        if binding.modifiers.contains(.maskCommand) { parts.append("\u{2318}") }
        parts.append(keyName(UInt16(binding.keyCode)))
        return parts.joined()
    }

    private func keyName(_ keyCode: UInt16) -> String {
        let map: [UInt16: String] = [
            0x00: "A", 0x01: "S", 0x02: "D", 0x03: "F", 0x04: "H", 0x05: "G", 0x06: "Z",
            0x07: "X", 0x08: "C", 0x09: "V", 0x0B: "B", 0x0C: "Q", 0x0D: "W", 0x0E: "E",
            0x0F: "R", 0x10: "Y", 0x11: "T", 0x12: "1", 0x13: "2", 0x14: "3", 0x15: "4",
            0x17: "5", 0x16: "6", 0x1A: "7", 0x1C: "8", 0x19: "9", 0x1D: "0", 0x1F: "O",
            0x20: "U", 0x22: "I", 0x23: "P", 0x25: "L", 0x26: "J", 0x28: "K", 0x2D: "N", 0x2E: "M",
        ]
        return map[keyCode] ?? "?"
    }
}
