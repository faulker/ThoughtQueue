import Cocoa
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "CaptureService")

/// Captures selected text and writes it to the store. Capture is instant: the note is
/// written first, then auto-intel runs async and can rename/move via the review toast.
final class CaptureService {
    static let shared = CaptureService()

    private init() {}

    /// Quick capture: grab the selection, write to the default sink (working doc append,
    /// else a new note in the working doc's category, else Uncategorized), return instantly.
    func quickCapture() {
        grabSelectedText { [weak self] text, savedClipboard in
            guard let self = self else { return }
            // No-op on empty OR whitespace-only selection; never save a blank note (rule #4).
            guard let text = text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                restoreClipboard(savedClipboard)
                ToastWindow.show(message: "No text selected")
                return
            }
            restoreClipboard(savedClipboard)
            self.persistCapture(text: text)
        }
    }

    /// Detailed capture: grab the selection and open the capture panel for edit + target choice.
    func showDetailedCapture() {
        grabSelectedText { text, savedClipboard in
            restoreClipboard(savedClipboard)
            CapturePanel.shared.show(with: text ?? "")
        }
    }

    /// Result of a capture attempt, surfaced for testing and feedback.
    enum CaptureResult: Equatable {
        case empty
        case appended(String)   // working-doc title
        case created
        case failed
    }

    /// Write a quick capture using the working-document sink rules, then kick off auto-intel.
    /// New notes are created immediately with a default title; auto-intel refines via the toast.
    @discardableResult
    func persistCapture(text: String) -> CaptureResult {
        let store = NoteStore.shared
        let prefs = PreferencesManager.shared

        // Defensive: never persist whitespace-only text (rule #4).
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            ToastWindow.show(message: "No text selected")
            return .empty
        }

        // Append to the working document if one is set and still exists (rule #6).
        if let workingURL = prefs.workingDocumentURL {
            if FileManager.default.fileExists(atPath: workingURL.path),
               let root = store.rootURL,
               let note = Note.from(url: workingURL, storeRoot: root),
               store.append(to: note, text: text) {
                ToastWindow.show(message: "Appended to \(note.title)")
                return .appended(note.title)
            } else {
                // Working doc deleted/moved externally (or append failed): clear the stale
                // setting and fall through to a new note instead of recreating a dead path.
                prefs.workingDocumentURL = nil
                log.warning("Working document missing; cleared setting")
            }
        }

        // Otherwise create a new note. Default category = working doc's folder, else Uncategorized.
        let defaultCategory = defaultCategoryFromWorkingDoc()
        guard let note = store.createNote(title: "", body: text, category: defaultCategory) else {
            ToastWindow.show(message: "Failed to save")
            return .failed
        }
        ToastWindow.show(message: "Captured!")

        // Async auto-title/categorize; never blocks capture.
        AutoIntelService.shared.process(note: note, body: text)
        return .created
    }

    /// The category to use for a brand-new capture: the working document's folder if set,
    /// otherwise nil (Uncategorized).
    private func defaultCategoryFromWorkingDoc() -> String? {
        guard let workingURL = PreferencesManager.shared.workingDocumentURL,
              let root = NoteStore.shared.rootURL,
              let note = Note.from(url: workingURL, storeRoot: root) else {
            return nil
        }
        return note.category
    }

    // MARK: - Selection grab (simulate Cmd+C, poll/restore pasteboard)

    /// Unlikely-to-occur sentinel seeded into the pasteboard before Cmd+C, so we can detect
    /// a real copy by VALUE change even when the selection equals the prior clipboard (rule #5).
    private static let copySentinel = "\u{200B}TQ-CAPTURE-SENTINEL-\u{200B}"

    private func grabSelectedText(completion: @escaping (String?, [[NSPasteboard.PasteboardType: Data]]) -> Void) {
        let pasteboard = NSPasteboard.general
        let savedClipboard = saveClipboard()

        // Seed a sentinel value. If after Cmd+C the pasteboard still equals the sentinel,
        // nothing was copied (no selection). Otherwise the new string is the selection,
        // even if it happens to match what the user had on the clipboard before.
        pasteboard.clearContents()
        pasteboard.setString(Self.copySentinel, forType: .string)

        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x08, keyDown: false) else {
            completion(nil, savedClipboard)
            return
        }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)

        DispatchQueue.global(qos: .userInitiated).async {
            var text: String?
            // Bumped to 20 attempts (~1s) for slower apps.
            for _ in 1...20 {
                Thread.sleep(forTimeInterval: 0.05)
                if let current = pasteboard.string(forType: .string), current != Self.copySentinel {
                    text = current
                    break
                }
            }
            DispatchQueue.main.async { completion(text, savedClipboard) }
        }
    }
}

// MARK: - Clipboard Save/Restore

func saveClipboard() -> [[NSPasteboard.PasteboardType: Data]] {
    let pb = NSPasteboard.general
    guard let items = pb.pasteboardItems else { return [] }
    return items.map { item in
        var dict: [NSPasteboard.PasteboardType: Data] = [:]
        for type in item.types {
            if let data = item.data(forType: type) { dict[type] = data }
        }
        return dict
    }
}

func restoreClipboard(_ saved: [[NSPasteboard.PasteboardType: Data]]) {
    let pb = NSPasteboard.general
    pb.clearContents()
    guard !saved.isEmpty else { return }
    let items = saved.map { dict -> NSPasteboardItem in
        let item = NSPasteboardItem()
        for (type, data) in dict { item.setData(data, forType: type) }
        return item
    }
    pb.writeObjects(items)
}
