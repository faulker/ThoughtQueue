import Cocoa
import os

private let log = Logger(subsystem: "com.thoughtqueue.app", category: "OpenWithService")

/// The two ways an open-with action can hand a note off.
enum OpenWithType: String, Codable {
    case command   // run a shell command, e.g. `zed {path}`
    case appInput  // activate an app then simulate keystrokes
}

/// For appInput actions: what to inject after activating the app.
enum OpenWithInputMode: String, Codable {
    case reference // type `@<abs-path>` (Claude file-reference style)
    case body      // paste the full note body
}

/// A configurable "Open with..." destination.
struct OpenWithAction: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var type: OpenWithType
    /// For command type: template with `{path}` placeholder.
    var commandTemplate: String? = nil
    /// For appInput type: target app bundle id.
    var appBundleId: String? = nil
    /// For appInput type: how to inject the note.
    var inputMode: OpenWithInputMode? = nil

    /// Built-in presets: Claude (appInput, reference) and Zed (command).
    static let presets: [OpenWithAction] = [
        OpenWithAction(
            name: "Claude",
            type: .appInput,
            commandTemplate: nil,
            appBundleId: "com.anthropic.claudefordesktop",
            inputMode: .reference
        ),
        OpenWithAction(
            name: "Zed",
            type: .command,
            commandTemplate: "zed {path}",
            appBundleId: nil,
            inputMode: nil
        ),
    ]
}

/// Runs open-with actions. Command type shells out via Process; appInput type
/// generalizes the old ClaudeIntegration: activate the app, then simulate keystrokes
/// posted to `.cgAnnotatedSessionEventTap` so they bypass our own event tap.
final class OpenWithService {
    static let shared = OpenWithService()

    private init() {}

    /// Expand a command template by literally substituting `{path}` with the note's path.
    /// Pure function used for display/routing tests. NOT safe to run via a shell directly;
    /// use `expandShellSafe` for that.
    static func expand(template: String, path: String) -> String {
        template.replacingOccurrences(of: "{path}", with: path)
    }

    /// Single-quote a string for safe use in a POSIX shell. Wraps in single quotes and
    /// escapes any embedded single quote as `'\''`, neutralizing spaces, `;`, `$`, quotes, etc.
    static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Expand a command template for shell execution, shell-quoting the substituted path so
    /// paths with spaces or metacharacters can neither break nor inject (rule #2).
    static func expandShellSafe(template: String, path: String) -> String {
        template.replacingOccurrences(of: "{path}", with: shellQuote(path))
    }

    /// Build a command template from a file the user picked via Browse. `.app` bundles are
    /// launched with `open -a`; anything else is treated as an executable. The chosen path is
    /// shell-quoted and `{path}` is appended so the note's path is passed as the argument.
    static func commandTemplate(forChosenURL url: URL) -> String {
        let quoted = shellQuote(url.path)
        if url.pathExtension.lowercased() == "app" {
            return "open -a \(quoted) {path}"
        }
        return "\(quoted) {path}"
    }

    /// Run an action against a note. Routes by action type.
    func run(action: OpenWithAction, note: Note, body: String) {
        switch action.type {
        case .command:
            runCommand(action: action, note: note)
        case .appInput:
            runAppInput(action: action, note: note, body: body)
        }
    }

    // MARK: - Command type

    private func runCommand(action: OpenWithAction, note: Note) {
        guard let template = action.commandTemplate, !template.isEmpty else {
            showError("\(action.name) has no command configured.")
            return
        }
        let command = Self.expandShellSafe(template: template, path: note.url.path)
        log.info("Running open-with command: \(command)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        // Use login shell so user PATH (e.g. zed) is available.
        process.arguments = ["-l", "-c", command]
        let pipe = Pipe()
        process.standardError = pipe

        process.terminationHandler = { proc in
            if proc.terminationStatus != 0 {
                let errData = pipe.fileHandleForReading.readDataToEndOfFile()
                let msg = String(data: errData, encoding: .utf8) ?? "exit \(proc.terminationStatus)"
                DispatchQueue.main.async {
                    self.showError("Command failed: \(msg.trimmingCharacters(in: .whitespacesAndNewlines))")
                }
            }
        }

        do {
            try process.run()
        } catch {
            showError("Failed to run command: \(error.localizedDescription)")
        }
    }

    // MARK: - App-input type

    private func runAppInput(action: OpenWithAction, note: Note, body: String) {
        guard let bundleId = action.appBundleId, !bundleId.isEmpty else {
            showError("\(action.name) has no app configured.")
            return
        }

        // App-input relies on keyboard simulation (CGEvent), which silently no-ops without
        // Accessibility permission. Check first so we don't activate the app and clobber the
        // clipboard with nothing pasted (rule #13).
        guard AXIsProcessTrusted() else {
            showError("Accessibility permission is required to send notes to \(action.name). Grant it in System Settings > Privacy & Security > Accessibility, then try again.")
            return
        }

        let inputMode = action.inputMode ?? .reference

        let workspace = NSWorkspace.shared
        guard let appURL = workspace.urlForApplication(withBundleIdentifier: bundleId) else {
            showError("\(action.name) app not found. Please install it first.")
            return
        }

        let savedClipboard = saveClipboard()
        let payload: String = (inputMode == .reference) ? "@\(note.url.path)" : body

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(payload, forType: .string)

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true

        workspace.openApplication(at: appURL, configuration: config) { [weak self] _, error in
            if let error = error {
                DispatchQueue.main.async {
                    restoreClipboard(savedClipboard)
                    self?.showError("Failed to open \(action.name): \(error.localizedDescription)")
                }
                return
            }

            // Claude-style: switch to chat, start a new chat, then paste.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if bundleId == "com.anthropic.claudefordesktop" {
                    self?.simulateKeystroke(keyCode: 0x12, flags: [.maskCommand])              // Cmd+1
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        self?.simulateKeystroke(keyCode: 0x1F, flags: [.maskCommand, .maskShift]) // Cmd+Shift+O (new chat)
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                            self?.simulateKeystroke(keyCode: 0x09, flags: [.maskCommand])         // Cmd+V
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                restoreClipboard(savedClipboard)
                            }
                        }
                    }
                } else {
                    // Generic app: just paste into the frontmost field.
                    self?.simulateKeystroke(keyCode: 0x09, flags: [.maskCommand])                 // Cmd+V
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                        restoreClipboard(savedClipboard)
                    }
                }
            }
        }
    }

    private func simulateKeystroke(keyCode: UInt16, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false) else {
            log.error("Failed to create CGEvent for keyCode \(keyCode)")
            return
        }
        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cgAnnotatedSessionEventTap)
        keyUp.post(tap: .cgAnnotatedSessionEventTap)
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Open With Error"
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
