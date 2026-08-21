# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Generate Xcode project (required after changing project.yml or adding/removing files)
xcodegen generate

# Build
xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueue -configuration Debug build

# Run tests
xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueueTests test

# Or open in Xcode
open ThoughtQueue.xcodeproj
```

After adding or removing Swift source files, re-run `xcodegen generate` to update the xcodeproj.

Releases are built by `.github/workflows/release.yml` (tag push `v*` or manual run with a version bump). The version lives in `ThoughtQueue/Info.plist`; the workflow overwrites it from the tag. See the Releasing section of `README.md` for the secrets it uses.

## Architecture

**ThoughtQueue** is a macOS menu bar app (LSUIElement) for capturing text snippets and sending them to Claude Desktop. Swift + AppKit, no external dependencies.

### Core flow

1. User selects text in any app, hits a global hotkey
2. `HotkeyManager` (CGEventTap) fires, calls `CaptureService`
3. `CaptureService` simulates Cmd+C to grab selection, stores in SQLite via `DatabaseManager`
4. User later clicks "Open" on an entry
5. `ClaudeIntegration` activates Claude Desktop, simulates Cmd+Shift+O (new chat) then Cmd+V (paste)

### Key patterns

- **Singletons** for all services: `DatabaseManager.shared`, `CaptureService.shared`, `ClaudeIntegration.shared`, `PreferencesManager.shared`, `UpdateService.shared`
- **NotificationCenter** with `.notesDidChange` for UI synchronization across all views
- **Raw SQLite3 C API** (no ORM), database at `~/Library/Application Support/ThoughtQueue/thoughtqueue.db`
- **Pure helpers** in `Store/`: `FuzzySearch.swift` and `TaskList.swift` are dependency-free statics (no filesystem, no UI) so they are directly unit-testable. `TaskList` owns all task-line parsing and rewriting, kept surgical so a toggle preserves bullets, indentation, trailing content, and CRLF endings.
- **CGEvent** for both hotkey capture and keyboard simulation, requires Accessibility permission, app is non-sandboxed

<!-- TODO: the DatabaseManager / ClaudeIntegration / SQLite lines above are stale. The store is filesystem-backed (`NoteStore`, plain `.md` files under the store folder); Claude Desktop is one preset of `OpenWithService`. -->

### UI layers

- **Left-click menu bar icon**: `PopoverController` shows searchable note rows with quick actions, "+ Add", and "+ List" (a new note pre-filled with one empty checkbox item). Deleting confirms inline inside `NoteRowView` (the action strip swaps for a "Delete?" prompt, auto-cancelling on mouse-out or after a few seconds), never via a modal alert
- **Double-click menu bar icon**: Opens the working document in a note window (`AppDelegate.statusItemAction` routes on `NSEvent.clickCount`; the first click still opens the popover, the second dismisses it)
- **Right-click menu bar icon**: Context menu with Categories, Preferences, Quit
- **CategoryManagerWindowController**: Singleton window for adding, renaming, and deleting category folders (delete moves notes to Uncategorized). Opened from the right-click menu.
- **NoteWindowController**: The single note window for creating, viewing, and editing a note (inline editable title + category dropdown, view/edit toggle). Used by "+ Add Note" and detailed capture alike. Its content is an `NSSplitViewController`: `NoteNavigatorViewController` in a collapsible sidebar item (hidden by default, toggled from the header or Ctrl+Cmd+S) plus `NoteEditorViewController`. Reach the editor from a window via `NSWindow.noteEditor`.
- **Checkbox lists**: a list note (`TaskList.isChecklist` true: at least one task line, and every other line blank or a heading) is presented by `ChecklistViewController`, a stack of live row views, *instead of* the markdown text view. It is not an edit mode: there is no view/edit toggle on a list note, boxes are always clickable, and each item is its own `NSTextField`. `NoteEditorViewController.ContentMode` (`checklist` / `rendered` / `raw`) is chosen by `desiredMode()`, where checklist outranks `startInEditMode` and ignores the `noteEditMode` preference entirely. The escape hatch is View > Edit as Markdown (Shift+Cmd+M, `toggleChecklistMarkdown:`), which sets `forceMarkdownForSession` until the window retargets.
- **Row round-trip**: `Store/TaskListRows.swift` decomposes a body into `TaskList.Row` values and back. Only edited lines are rewritten, and `row(from:)` re-serializes its own candidate and falls back to `.other` on any mismatch, so `body(from: rows(from: s)) == s` holds for every input (fuzz-tested). That is what lets ticking one box leave the rest of the file byte-identical, CRLF included.
- **Mixed prose+task notes keep the old path**: `MarkdownRenderer` stamps `.tqTaskSourceLine` / `.tqTaskCheckbox`, `ModeSwitchingTextView.taskHit(at:)` hit-tests and swallows the click ahead of edit activation, and `NoteEditorViewController.toggleTask(onSourceLine:)` rewrites via `TaskList`, guarded by `renderedBody`. This also serves lists longer than `ChecklistViewController.maxRows`, which fall back to rendered markdown.
- The note window's text view is deliberately TextKit 1 (`ModeSwitchingTextView(usingTextLayoutManager: false)`): the renderer emits `NSTextTable` blocks that only TextKit 1 lays out, and checkbox hit testing needs `NSLayoutManager` geometry.
- **NoteNavigatorViewController**: The note window's navigation panel. Source-list outline of notes grouped by category with a fuzzy search field; selecting a note retargets the same window via `NoteEditorViewController.load(note:)`, unless that note already has its own window (which is focused via `NoteWindowController.focus`, including deminiaturize and `.moveToActiveSpace`). Right-click a note to set or unset the working document. It loads its tree in `viewDidLoad`, so the panel is never blank even if AppKit puts it on screen before the first explicit `reload()`.

Window levels stack deliberately: pinned note windows sit at `NoteWindowController.pinnedLevel` (`.normal` + 1), Preferences one step above that (`PreferencesWindowController.level`), and both stay below `.floating` so other apps' annotation overlays are not covered.

### Visual design ("Organic" theme)

`Theme.swift` is the single source of truth for the cream/sage light palette and its dark counterpart (every color is a light/dark `NSColor` pair via `NSColor(light:dark:)`, so it tracks system appearance automatically), plus the bundled Figtree body font (`Theme.body`) and Georgia accent font (`Theme.heading`). `ThemedControls.swift` holds the reusable custom-drawn controls built on those tokens: `ThemedButton` (filled/outlined pill buttons), `ThemedSearchField` (flat pill search input), `SegmentedPillControl` (two-way toggle, e.g. the editor font quick-picker), `ThemedCheckbox` (custom-drawn checkbox used by the checklist rows; drawn in `draw(_:)` rather than `updateLayer()` because it strokes a box and a tick, and its checkmark path is flip-aware). New UI should pull colors/fonts from `Theme` rather than system colors, except where a control's native chrome is left as-is deliberately (e.g. `NSPopUpButton`, native checkboxes, and `NoteNavigatorViewController`'s `NSSearchField`, which tests drive directly).

The interface font is user-configurable: `PreferencesManager.uiFontFamily` (nil = bundled Figtree, `Theme.systemFamily` = system font, otherwise an installed family) and `uiFontScale` feed `Theme.body`/`Theme.heading`, and `Theme.metric(_:)` scales layout constants (row heights, control heights) by the same factor so bigger text doesn't clip. Changing either posts `.uiFontDidChange`; views pick the new font up as they are rebuilt (the popover rebuilds on every open).

Figtree ships in `ThoughtQueue/Resources/Fonts/Figtree.ttf` (a variable font; `Theme.body` addresses its named weight instances directly, e.g. `Figtree-SemiBold`) and is registered automatically via `ATSApplicationFontsPath` in Info.plist — no manual registration code needed.

Appearance (Dark/Light/System) is a Preferences toggle backed by `PreferencesManager.themeMode`; its setter is the single place that pushes the choice onto `NSApp.appearance` (`PreferencesManager.applyThemeMode`), also called once at launch from `AppDelegate` to restore a non-default choice.

### Auto-update

`UpdateService` checks GitHub Releases at launch and on a preference-controlled interval (skipped for local Xcode / `build.sh` products under `DerivedData` or `Build/Products`). The check is a `HEAD` against the public `releases/latest` URL whose 302 redirect carries the version tag: deliberately **not** the GitHub API, so there is no auth or rate limit. Updating downloads the release zip, verifies it against the release's `checksums-sha256.txt` asset, validates the unpacked bundle's id and version, then hands the swap to a detached shell script that waits for the app to exit before replacing it and relaunching. Version math and checksum parsing are pure statics so they are testable without the network.

### Default hotkeys

- Cmd+Shift+B: Quick capture (instant save to Uncategorized)
- Cmd+Shift+Option+B: Detailed capture (overlay with edit + category picker)

Hotkeys are customizable via Preferences and stored in UserDefaults.

### Claude Desktop integration

Bundle ID: `com.anthropic.claudefordesktop`. Integration uses keyboard simulation (CGEvent), not APIs. The `claude://` URL scheme only activates the app without parameters.

## Model Selection

Choose the model based on the task in this codebase:

- **Claude Fable 5** (`claude-fable-5`): CGEvent hotkey/keyboard-simulation logic, Accessibility permission and non-sandboxed edge cases, Claude Desktop integration timing bugs, and any tricky AppKit event handling.
- **Claude Opus 4.8** (`claude-opus-4-8`): default for features spanning services, new capture flows, or changes touching multiple UI layers (popover, main window, note window).
- **Claude Sonnet 5** (`claude-sonnet-5`): routine SwiftUI/AppKit tweaks, SQLite query changes, small bug fixes, and test updates.
- **Claude Haiku 4.5** (`claude-haiku-4-5`): quick lookups, doc edits, and boilerplate like new Preferences fields.
