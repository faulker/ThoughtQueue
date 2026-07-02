# Deferred Work

Issues surfaced during review of `spec-thoughtqueue-mvp.md` that are intentionally not fixed in this pass. Pre-existing/architectural limitations or low-value polish.

## From ThoughtQueue MVP review (2026-06-25)

- **Pasteboard timing race in keyboard simulation.** Capture (`Cmd+C` grab) and the app-input "Open with…" both save/replace/restore the clipboard on fixed timers (0.5–1.0s). If the user changes the clipboard during the window, or the target app is slow, content can be clobbered or stale. This is inherent to the keyboard-simulation approach inherited from the reference app; a robust fix needs app-readiness signaling, not timers. (Medium, architectural)
- **ShortcutRecorder keyName map incomplete.** Punctuation, function keys, arrows, and space render as "?" while still binding correctly. (Low, cosmetic)
- **Security-scoped bookmark not refreshed when stale.** If the store folder is moved/renamed, the stale bookmark is resolved but not re-saved; eventual loss of access. (Low)
- **FolderWatcher debounce/feedback-loop timing not unit-tested.** FSEvents timing is hard to cover in XCTest; verified manually. (Low)
- **Capture panel focus behavior.** `NSApp.activate(ignoringOtherApps:)` on a non-activating panel can pull focus from the source app; acceptable for now. (Low)
- **XCTest shares the NoteStore singleton.** Fine while tests run serially; revisit if parallelized. (Low)
