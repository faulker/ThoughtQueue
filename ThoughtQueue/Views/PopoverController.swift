import Cocoa

/// Left-click popover: a search field over the full notes list with per-row quick actions.
final class PopoverController: NSObject, NSPopoverDelegate {
    private let popover = NSPopover()
    private let viewController = PopoverViewController()
    private var globalMonitor: Any?
    private var localMonitor: Any?

    override init() {
        super.init()
        popover.contentViewController = viewController
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 380, height: 440)
        viewController.onRequestClose = { [weak self] in self?.popover.close() }
    }

    func toggle(relativeTo rect: NSRect, of view: NSView) {
        if popover.isShown {
            popover.close()
        } else {
            // A status-item popover otherwise inherits the appearance of the menu bar's own
            // (dark) window rather than the app's chosen theme, leaving it stuck dark regardless
            // of the Light/Dark/System preference. `NSApp.effectiveAppearance` already reflects
            // that preference (`PreferencesManager.applyThemeMode` keeps it in sync), so force
            // the popover to match it explicitly, freshly on every open in case the theme
            // changed since the last time it was shown.
            popover.appearance = NSApp.effectiveAppearance
            viewController.reload()
            popover.show(relativeTo: rect, of: view, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
            startEventMonitors()
        }
    }

    /// Dismiss the popover if it is showing. No-op otherwise.
    func close() {
        popover.close()
    }

    private func startEventMonitors() {
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.close()
            }
        }
        if localMonitor == nil {
            localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
                guard let self, let popoverWindow = self.popover.contentViewController?.view.window else { return event }
                if event.window !== popoverWindow { self.popover.close() }
                return event
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let g = globalMonitor { NSEvent.removeMonitor(g); globalMonitor = nil }
        if let l = localMonitor { NSEvent.removeMonitor(l); localMonitor = nil }
    }
}

final class PopoverViewController: NSViewController {
    var onRequestClose: (() -> Void)?

    private var searchField: ThemedSearchField!
    private var stackView: NSStackView!
    private var allNotes: [Note] = []
    private var filtered: [Note] = []
    private var reloadWorkItem: DispatchWorkItem?

    override func loadView() {
        let container = ThemedSurfaceView(frame: NSRect(x: 0, y: 0, width: 380, height: 440))

        let addButton = ThemedButton(title: "+ Add", prominent: true, target: self, action: #selector(addNote))
        container.addSubview(addButton)

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(separator)

        searchField = ThemedSearchField()
        searchField.placeholderString = "Search notes\u{2026}"
        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.onChange = { [weak self] _ in self?.applyFilter() }
        container.addSubview(searchField)

        stackView = NSStackView()
        stackView.orientation = .vertical
        stackView.alignment = .width
        stackView.spacing = 4

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let flip = FlippedView()
        flip.translatesAutoresizingMaskIntoConstraints = false
        flip.addSubview(stackView)
        stackView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            stackView.topAnchor.constraint(equalTo: flip.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: flip.leadingAnchor, constant: 8),
            stackView.trailingAnchor.constraint(equalTo: flip.trailingAnchor, constant: -8),
            stackView.bottomAnchor.constraint(equalTo: flip.bottomAnchor, constant: -8),
        ])
        scrollView.documentView = flip
        container.addSubview(scrollView)
        flip.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        // Rows scrolling out from under a stationary cursor don't get a mouseExited on their
        // own (AppKit only updates tracking areas on actual mouse movement), which otherwise
        // leaves their hover highlight stuck. Recompute it directly on every scroll tick.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollViewDidScroll), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: separator.topAnchor),

            separator.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            separator.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -10),

            addButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            addButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            addButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            addButton.heightAnchor.constraint(equalToConstant: Theme.metric(32)),
        ])

        self.view = container
        NotificationCenter.default.addObserver(self, selector: #selector(onNotesChanged), name: .notesDidChange, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func onNotesChanged() {
        let schedule = { [weak self] in
            self?.reloadWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.reload() }
            self?.reloadWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
        }
        if Thread.isMainThread { schedule() } else { DispatchQueue.main.async { schedule() } }
    }

    func reload() {
        _ = view
        allNotes = NoteStore.shared.allNotes()
        applyFilter()
    }

    @objc private func scrollViewDidScroll() {
        for case let row as NoteRowView in stackView.arrangedSubviews {
            row.refreshHoverState()
        }
    }

    private func applyFilter() {
        let query = searchField?.stringValue ?? ""
        filtered = FuzzySearch.rank(notes: allNotes, query: query)
        rebuild()
    }

    private func rebuild() {
        stackView.arrangedSubviews.forEach { $0.removeFromSuperview() }

        if filtered.isEmpty {
            let empty = NSTextField(labelWithString: allNotes.isEmpty ? "No notes yet." : "No matches.")
            empty.font = Theme.body(13)
            empty.textColor = Theme.textSecondary
            empty.alignment = .center
            stackView.addArrangedSubview(empty)
            return
        }

        for note in filtered {
            let row = NoteRowView(note: note, compact: true) { [weak self] in self?.onRequestClose?() }
            stackView.addArrangedSubview(row)
        }
    }

    @objc private func addNote() {
        onRequestClose?()
        NoteWindowController.showNew()
    }
}

final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
