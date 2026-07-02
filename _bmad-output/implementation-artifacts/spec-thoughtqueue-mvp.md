---
title: 'ThoughtQueue MVP: filesystem-backed quick notes app (greenfield rebuild)'
type: 'feature'
created: '2026-06-25'
status: 'done'
baseline_commit: '7f4e1d1f4c58f9ca836ad8745e94d28f534ce854'
context:
  - '{project-root}/_bmad-output/planning-artifacts/briefs/brief-ThoughtQueue-2026-06-25/brief.md'
  - '{project-root}/_bmad-output/planning-artifacts/briefs/brief-ThoughtQueue-2026-06-25/addendum.md'
---

<frozen-after-approval reason="human-owned intent — do not modify unless human renegotiates">

## Intent

**Problem:** ThoughtQueue should be a fast, personal macOS quick-notes app that is a thin shell over a folder of plain markdown files the user fully owns, not a SQLite-backed capture tool. The current app stores entries in a database, hides organization from the filesystem, and only sends to Claude.

**Approach:** Greenfield rebuild as a menu-bar app where the filesystem is the source of truth. Notes are plain `.md` files in a user-chosen folder; category = folder, title = filename, date = file timestamps; no frontmatter. Reuse the proven menu-bar shell, CGEvent capture, and keyboard-simulation patterns from `reference/`, replacing the SQLite layer with filesystem operations and a folder watcher. Add a generalized "Open with…" (command + app-input types) with Claude `@path` context handoff, fuzzy title search, in-app view/edit, and Apple Foundation Models auto-title/auto-categorize with an editable review toast.

## Boundaries & Constraints

**Always:**
- Notes are plain `.md` files in the configured store folder. Metadata is the filesystem: category = folder (one level), title = filename (slug), dates = FileManager created/modified attributes. No YAML frontmatter, no DB, no sidecar metadata files.
- The store folder contains only notes (and category subfolders). No app config, index, or clutter written into it.
- Capture is instant and never blocks on the LLM. The note is written first; auto-title/categorize runs async and can rename/move the file afterward via the review toast.
- The app is a shell over the folder: two-way sync. External edits/moves/deletes/renames are reflected in the app; app actions write through to the folder.
- App config (store location, working document, click behavior, open-with definitions, hotkeys, toast timeout) lives in UserDefaults, never in the store folder.
- Non-sandboxed app; CGEvent capture and inter-app keyboard simulation require Accessibility permission (prompt at launch, same flow as reference).
- Auto-intelligence is gated behind `#available(macOS 26, *)` + Foundation Models availability checks; when unavailable it degrades gracefully (default title from first non-empty line or timestamp; category = current working document's folder, else Uncategorized).

**Ask First:**
- Choosing the default store-folder location on first run (propose a default, let the user confirm/change before any note is written).
- Any destructive filesystem behavior beyond single-note delete (e.g. deleting a category folder with notes in it).
- Filename collision policy if the chosen scheme still collides (default: append a short timestamp/counter suffix).

**Never:**
- No accounts, sync services, payments, or any network/SaaS dependency (auto-intel is on-device only).
- No knowledge-base / wiki / document-management features (backlinks, graphs, tags database, nested hierarchies beyond one folder level for categories).
- No proprietary storage or making a note unusable outside the app.
- Do not modify anything under `reference/` (read-only archive of the old app).

## I/O & Edge-Case Matrix

| Scenario | Input / State | Expected Output / Behavior | Error Handling |
|----------|--------------|---------------------------|----------------|
| Quick capture (new note) | Hotkey with text selected | `Cmd+C` grab, write `<slug>-<timestamp>.md` into working doc's folder (or Uncategorized), post change notification | If no text grabbed, no-op with brief feedback |
| Capture → append | Capture with append target chosen | Append captured text (with separator) to the chosen existing `.md` | If target missing/deleted, fall back to new note |
| Working-document sink | Working doc set, capture with no explicit target | Capture lands in/append to the working document by default | If working doc deleted externally, clear setting + create new note |
| Filename collision | Two notes resolve to same filename | Second gets a unique suffix; no overwrite | Never overwrite an existing file |
| External edit/move/delete | File changed in Finder/editor while app open | App list reflects the change (title/category/date) within ~1s | Debounce events; ignore app's own writes |
| Fuzzy title search | Query string | Ranked matches across all note titles | Empty query → full list |
| Open-with: command type | Note + command template `zed {path}` | Run command with `{path}` substituted by the note's absolute path | Surface non-zero exit / missing binary |
| Open-with: app-input (Claude `@path`) | Note + Claude app-input action | Activate Claude, new chat, type `@<abs-path>` (or paste body) via keyboard sim | If app not installed, error toast |
| Auto-title/categorize (available) | New note body, macOS 26 + Apple Intelligence | Async: model proposes title+category; review toast shows result with Edit + user-set timeout | On model error, keep default title/category silently |
| Auto-intel unavailable | macOS < 26 or AI disabled | Default title (first line/timestamp) + Uncategorized/working-doc category, no toast nag | Feature simply off |

</frozen-after-approval>

## Code Map

New app at repo root (old app preserved under `reference/`). Generated via xcodegen from `project.yml` (model the new one on `reference/project.yml`).

- `project.yml` -- xcodegen spec: LSUIElement menu-bar app, bundle id, non-sandboxed entitlements, app + test targets. App deployment target macOS 14; AI code path gated to macOS 26.
- `build.sh` -- regenerate + build (adapt from existing).
- `ThoughtQueue/main.swift` -- NSApplication + AppDelegate entry (from reference).
- `ThoughtQueue/AppDelegate.swift` -- status item, left-click popover / right-click menu, Accessibility prompt, folder-watcher startup.
- `ThoughtQueue/Store/NoteStore.swift` -- **replaces DatabaseManager**. FileManager-backed CRUD over the store folder: list categories (folders) + notes, create/append/update/move/rename/delete note, slug+collision naming, read body, dates from attributes. Posts `.notesDidChange`.
- `ThoughtQueue/Store/Note.swift` -- value type derived from a file URL (title=filename, category=parent folder, createdAt/modifiedAt from attributes).
- `ThoughtQueue/Store/FolderWatcher.swift` -- FSEvents/DispatchSource watcher on the store root (recursive, debounced); ignores self-originated writes; posts `.notesDidChange`.
- `ThoughtQueue/Services/HotkeyManager.swift` -- CGEvent tap + permission polling (from reference).
- `ThoughtQueue/Services/CaptureService.swift` -- grab selection via simulated `Cmd+C`; new-vs-append; working-doc sink; append-target picker.
- `ThoughtQueue/Services/OpenWithService.swift` -- run open-with actions: command type (Process) and app-input type (generalized from ClaudeIntegration keyboard-sim). Ships predefined Claude (`@path`) + Zed (`zed {path}`).
- `ThoughtQueue/Services/AutoIntelService.swift` -- `@available(macOS 26, *)` Foundation Models call (`@Generable` struct {title, category}); async, non-blocking; graceful fallback.
- `ThoughtQueue/Services/PreferencesManager.swift` -- UserDefaults: store location, working document, click behavior, open-with defs, hotkeys, toast timeout, start-at-login (from reference).
- `ThoughtQueue/Views/PopoverController.swift` -- left-click popover: notes list, search field, quick actions.
- `ThoughtQueue/Views/MainWindowController.swift` -- split view: category sidebar + notes table + note view/edit pane.
- `ThoughtQueue/Views/NoteDetailView.swift` -- click-behavior aware: run open command / render markdown / edit raw.
- `ThoughtQueue/Views/CapturePanel.swift` -- detailed capture: editable text + category + new-vs-append target picker (from reference DetailedCapturePanel).
- `ThoughtQueue/Views/ReviewToast.swift` -- transient panel under the status item: auto title+category + Edit button + user-set timeout.
- `ThoughtQueue/Views/PreferencesWindowController.swift` -- settings UI incl. store-location chooser, click behavior, open-with editor, working doc, hotkeys (from reference).
- `ThoughtQueueTests/NoteStoreTests.swift` -- filesystem CRUD on temp dir.
- `ThoughtQueueTests/SearchAndNamingTests.swift` -- fuzzy title search + slug/collision.
- `ThoughtQueueTests/OpenWithTests.swift` -- command-template `{path}` expansion + action-type routing.

## Tasks & Acceptance

**Execution:**
- [x] `project.yml`, `build.sh` -- scaffold xcodegen spec + build script for the new app and test targets (LSUIElement, non-sandboxed, macOS 14 target).
- [x] `ThoughtQueue/main.swift`, `AppDelegate.swift` -- menu-bar shell, status item, popover/menu, Accessibility prompt, start watcher.
- [x] `ThoughtQueue/Store/Note.swift`, `NoteStore.swift` -- filesystem note model + CRUD/append/move/rename/delete, slug+collision naming, `.notesDidChange`.
- [x] `ThoughtQueue/Store/FolderWatcher.swift` -- debounced recursive watcher; ignore self-writes; two-way sync.
- [x] `ThoughtQueue/Services/PreferencesManager.swift` -- store location (with first-run chooser), working doc, click behavior, open-with defs, hotkeys, toast timeout.
- [x] `ThoughtQueue/Services/HotkeyManager.swift`, `CaptureService.swift` -- hotkeys + selection capture; new-vs-append; working-doc sink; append picker.
- [x] `ThoughtQueue/Services/OpenWithService.swift` -- command + app-input action types; predefined Claude `@path` + Zed.
- [x] `ThoughtQueue/Services/AutoIntelService.swift` -- Foundation Models auto-title/categorize (macOS 26 gated), async + graceful fallback.
- [x] `ThoughtQueue/Views/*` -- popover, main window, note detail (click-behavior aware), capture panel, review toast, preferences.
- [x] `ThoughtQueueTests/*` -- NoteStore CRUD, search/naming, open-with template tests.

**Acceptance Criteria:**
- Given a configured store folder, when the user quick-captures selected text, then a `.md` file appears in the correct category folder and shows in the app, with capture returning instantly (no LLM wait).
- Given a working document is set, when the user captures without choosing a target, then the text is appended to that document.
- Given a note is moved/renamed/deleted in Finder, when the app is running, then the app's view reflects it within ~1s without duplicating or overwriting.
- Given the click-behavior setting, when the user clicks a note, then the app respectively runs the open command, renders markdown, or opens a raw editor.
- Given a Claude `@path` open-with action, when invoked on a note, then Claude is activated with a new chat referencing the note's absolute path.
- Given macOS < 26 or AI unavailable, when a note is captured, then it still gets a sensible default title/category and no error is shown.
- Given the app is removed, when the user opens the store folder, then all notes remain readable/editable as plain markdown with intact folder/filename/date organization.

## Verification

**Commands:**
- `xcodegen generate` -- expected: `ThoughtQueue.xcodeproj` created without errors.
- `xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueue -configuration Debug build` -- expected: build succeeds.
- `xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueueTests test` -- expected: all tests pass.

**Manual checks:**
- Grant Accessibility permission; verify hotkey capture and Claude `@path` handoff work on a real note.
- Edit a note externally and confirm the app reflects it.

## Design Notes

- **No frontmatter, filesystem is truth.** A `Note` is reconstructed from its file URL every read; never cache authoritative metadata elsewhere. Category is the immediate parent folder under the store root; notes directly in the root are "Uncategorized".
- **Self-write suppression.** The watcher must ignore events caused by the app's own writes (track recently-written paths / temporarily suspend) to avoid feedback loops.
- **Open-with generalization (from `reference/txtmem/Services/ClaudeIntegration.swift`):** app-input actions activate the target app then post keystrokes via `.cgAnnotatedSessionEventTap`. An action is `{name, type: command|appInput, command/template, appBundleId, inputMode: reference|body}`. Claude preset = appInput + reference (`@<abs-path>`); Zed preset = command (`zed {path}`).
- **Foundation Models:** define `@Generable struct NoteMeta { @Guide title: String; @Guide category: String }` and request it from the on-device session; run off the main actor; apply result through the review toast so the user can edit before the rename/move commits.

## Suggested Review Order

**Filesystem store & safety (the heart of the change)**

- Entry point: how a captured note becomes a file on disk.
  [`NoteStore.swift:241`](../../ThoughtQueue/Store/NoteStore.swift#L241)
- Security fix: category sanitization blocks path traversal (`..`, separators).
  [`NoteStore.swift:154`](../../ThoughtQueue/Store/NoteStore.swift#L154)
- Collision-proof naming, UUID fallback so a write can never overwrite.
  [`NoteStore.swift:202`](../../ThoughtQueue/Store/NoteStore.swift#L202)
- Ghost-file guard: aborts if the target was deleted/moved externally.
  [`NoteStore.swift:285`](../../ThoughtQueue/Store/NoteStore.swift#L285)

**Two-way sync**

- Per-path self-write suppression consumed by the matching FSEvent (no blanket timer).
  [`FolderWatcher.swift:75`](../../ThoughtQueue/Store/FolderWatcher.swift#L75)

**Capture**

- New-vs-append, working-doc sink, whitespace no-op, external-delete fallback.
  [`CaptureService.swift:48`](../../ThoughtQueue/Services/CaptureService.swift#L48)
- Sentinel-based selection grab so selection == clipboard still captures.
  [`CaptureService.swift:104`](../../ThoughtQueue/Services/CaptureService.swift#L104)

**Open-with handoff & safety**

- Shell-quoting of the substituted `{path}` (injection fix).
  [`OpenWithService.swift:72`](../../ThoughtQueue/Services/OpenWithService.swift#L72)
- Command-type runner using the shell-safe expansion.
  [`OpenWithService.swift:88`](../../ThoughtQueue/Services/OpenWithService.swift#L88)
- App-input handoff gated on Accessibility before clobbering the clipboard.
  [`OpenWithService.swift:131`](../../ThoughtQueue/Services/OpenWithService.swift#L131)

**On-device intelligence**

- Async, non-blocking; macOS-26 gated with graceful fallback.
  [`AutoIntelService.swift:27`](../../ThoughtQueue/Services/AutoIntelService.swift#L27)
- Apply validates the edited title/category before any rename/move.
  [`AutoIntelService.swift:119`](../../ThoughtQueue/Services/AutoIntelService.swift#L119)

**Rendering & UI**

- Block-level markdown incl. `- [ ]` task checkboxes.
  [`NoteDetailView.swift:88`](../../ThoughtQueue/Views/NoteDetailView.swift#L88)
- User-authored Open-with entries (add/edit/delete).
  [`PreferencesWindowController.swift:16`](../../ThoughtQueue/Views/PreferencesWindowController.swift#L16)
- First-run store-folder chooser (Ask-First on default location).
  [`AppDelegate.swift:47`](../../ThoughtQueue/AppDelegate.swift#L47)

**Tests (supporting)**

- Store CRUD, sanitization, collision safety, capture fallbacks.
  [`NoteStoreTests.swift:1`](../../ThoughtQueueTests/NoteStoreTests.swift#L1)
- Open-with `{path}` quoting + routing.
  [`OpenWithTests.swift:1`](../../ThoughtQueueTests/OpenWithTests.swift#L1)
