import Cocoa
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "AppDelegate")

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private let popoverController = PopoverController()
    private var hotkeyManager: HotkeyManager?
    private var folderWatcher: FolderWatcher?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Skip all launch side effects (modals, hotkeys, watchers) when running under XCTest.
        if NSClassFromString("XCTestCase") != nil { return }

        log.info("ThoughtQueue launching")

        // Apply a stored light/dark override before any window is created (a no-op for the
        // default "system" mode, since NSApp.appearance already starts nil).
        PreferencesManager.applyThemeMode(PreferencesManager.shared.themeMode)

        // Show button/icon tooltips almost immediately instead of after the ~1s default (fix #4).
        UserDefaults.standard.set(150, forKey: "NSInitialToolTipDelay")

        setupMainMenu()
        setupStatusItem()

        // Configure the store: use the saved folder, or prompt the user on first run.
        // Both paths run synchronously, so the store root is set by the time we return.
        if let url = PreferencesManager.shared.storeURL {
            NoteStore.shared.rootURL = url
            startWatcher()
        } else {
            promptForStoreFolder()
        }

        // Mirror settings into the store folder (default on) once the root is known.
        SettingsSync.shared.start()

        // Accessibility permission for hotkeys + keyboard simulation.
        if !AXIsProcessTrusted() {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
            AXIsProcessTrustedWithOptions(options)
        }

        let hk = HotkeyManager(
            onQuickCapture: { CaptureService.shared.quickCapture() },
            onDetailedCapture: { CaptureService.shared.showDetailedCapture() }
        )
        hk.register()
        hotkeyManager = hk

        observeWindowVisibility()

        // Arm the periodic check, then check once at launch. The delay keeps the network call
        // off the startup path so a slow or offline connection can't stall the menu bar icon.
        UpdateService.shared.startScheduler()
        if PreferencesManager.shared.autoUpdateCheckEnabled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
                UpdateService.shared.check(userInitiated: false)
            }
        }
    }

    // MARK: - Activation policy

    /// Watch every window's open/close so the app can appear in the Dock and Cmd-Tab
    /// switcher only while a real window is on screen.
    private func observeWindowVisibility() {
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(windowVisibilityChanged), name: NSWindow.didBecomeMainNotification, object: nil)
        nc.addObserver(self, selector: #selector(windowWillClose), name: NSWindow.willCloseNotification, object: nil)
    }

    @objc private func windowVisibilityChanged(_ notification: Notification) {
        updateActivationPolicy()
    }

    @objc private func windowWillClose(_ notification: Notification) {
        // willClose fires while the window is still in NSApp.windows, so re-check next runloop.
        DispatchQueue.main.async { [weak self] in self?.updateActivationPolicy() }
    }

    /// Promote to a regular app (Dock + Cmd-Tab) while any main-capable window is visible,
    /// and demote back to a menu-bar-only accessory app once they all close. The status
    /// item, popover, capture panel, and toasts are panels/borderless windows that never
    /// become main, so they don't count.
    private func updateActivationPolicy() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
        let target: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        guard NSApp.activationPolicy() != target else { return }
        NSApp.setActivationPolicy(target)
        if target == .regular { NSApp.activate(ignoringOtherApps: true) }
    }

    // MARK: - First-run store chooser

    /// Propose a default store folder and let the user confirm or pick another, before
    /// any note is written.
    private func promptForStoreFolder() {
        let prefs = PreferencesManager.shared
        let proposed = prefs.defaultStoreURL

        let alert = NSAlert()
        alert.messageText = "Choose your notes folder"
        alert.informativeText = "ThoughtQueue stores notes as plain markdown files in a folder you own.\n\nProposed: \(proposed.path)"
        alert.addButton(withTitle: "Use Proposed")
        alert.addButton(withTitle: "Choose Another\u{2026}")
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            try? FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
            prefs.storeURL = proposed
            NoteStore.shared.rootURL = proposed
            startWatcher()
        } else {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.allowsMultipleSelection = false
            panel.prompt = "Choose"
            panel.directoryURL = proposed.deletingLastPathComponent()
            if panel.runModal() == .OK, let url = panel.url {
                prefs.storeURL = url
                NoteStore.shared.rootURL = url
                startWatcher()
            } else {
                // No folder chosen: fall back to the proposed default so the app stays usable.
                try? FileManager.default.createDirectory(at: proposed, withIntermediateDirectories: true)
                prefs.storeURL = proposed
                NoteStore.shared.rootURL = proposed
                startWatcher()
            }
        }
    }

    // MARK: - Folder watcher

    func startWatcher() {
        folderWatcher?.stop()
        folderWatcher = nil
        guard let root = NoteStore.shared.rootURL else { return }
        let watcher = FolderWatcher(root: root)
        watcher.start()
        folderWatcher = watcher
    }

    /// Restart the watcher (e.g. after the store folder changes in Preferences).
    func restartWatcher() {
        startWatcher()
    }

    // MARK: - Menus

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "About ThoughtQueue", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        let prefsItem = NSMenuItem(title: "Preferences\u{2026}", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        appMenu.addItem(prefsItem)
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(title: "Quit ThoughtQueue", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let viewMenuItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        // Nil target: the action is dispatched down the responder chain, so it reaches the note
        // window that's key (and is disabled automatically when no note window is).
        let navigatorItem = NSMenuItem(title: "Show Notes Panel", action: Selector(("toggleNoteNavigator:")), keyEquivalent: "s")
        navigatorItem.keyEquivalentModifierMask = [.control, .command]
        navigatorItem.target = nil
        viewMenu.addItem(navigatorItem)
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        NSApp.mainMenu = mainMenu
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        if let button = item.button {
            button.image = makeMenuBarIcon()
            button.action = #selector(handleClick)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.target = self
            ReviewToast.shared.anchorButton = button
        }
    }

    private func makeMenuBarIcon() -> NSImage {
        let size: CGFloat = 18
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let s = rect.size.width
            let inset = s * 0.08
            let outlineRect = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
            let path = NSBezierPath(roundedRect: outlineRect, xRadius: s * 0.18, yRadius: s * 0.18)
            NSColor.controlTextColor.setStroke()
            path.lineWidth = 1.2
            path.stroke()

            let font = NSFont(name: "Georgia-Bold", size: s * 0.45) ?? NSFont.systemFont(ofSize: s * 0.45, weight: .heavy)
            let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.controlTextColor]
            let quote = NSAttributedString(string: "\u{201C}\u{201D}", attributes: attrs)
            let strSize = quote.size()
            quote.draw(at: NSPoint(x: (s - strSize.width) / 2, y: (s - strSize.height) / 2))
            return true
        }
        image.isTemplate = true
        return image
    }

    /// What a click on the menu bar icon should do.
    enum StatusItemAction: Equatable {
        case contextMenu
        case workingDocument
        case popover
    }

    /// Route a menu bar click by event type and click count. Pure so the routing is testable
    /// without synthesizing NSEvents.
    ///
    /// The single-click action is deliberately not deferred waiting on a possible second click:
    /// that would add `NSEvent.doubleClickInterval` of lag to every popover open. Instead the
    /// first click of a double opens the popover as usual and the second click dismisses it.
    static func statusItemAction(eventType: NSEvent.EventType, clickCount: Int) -> StatusItemAction {
        if eventType == .rightMouseUp { return .contextMenu }
        return clickCount >= 2 ? .workingDocument : .popover
    }

    @objc private func handleClick(_ sender: NSStatusBarButton) {
        guard let event = NSApp.currentEvent else { return }
        switch Self.statusItemAction(eventType: event.type, clickCount: event.clickCount) {
        case .contextMenu:
            showContextMenu()
        case .workingDocument:
            popoverController.close()
            openWorkingDocument()
        case .popover:
            popoverController.toggle(relativeTo: sender.bounds, of: sender)
        }
    }

    /// Open a window on the note set as the working document. Clears the preference when it
    /// points at a note that no longer exists, matching quick capture's stale-path handling.
    func openWorkingDocument() {
        if let note = NoteStore.shared.workingDocumentNote {
            NoteWindowController.show(note: note)
            return
        }
        if PreferencesManager.shared.workingDocumentURL != nil {
            PreferencesManager.shared.workingDocumentURL = nil
            log.warning("Working document missing; cleared setting")
            ToastWindow.show(message: "Working document is missing")
        } else {
            ToastWindow.show(message: "No working document set")
        }
    }

    private func showContextMenu() {
        guard let statusItem = statusItem else { return }
        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Categories\u{2026}", action: #selector(openCategoryManager), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Preferences\u{2026}", action: #selector(openPreferences), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApp.terminate), keyEquivalent: "q"))
        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openCategoryManager() {
        CategoryManagerWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openPreferences() {
        PreferencesWindowController.shared.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
