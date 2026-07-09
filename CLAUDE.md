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

## Architecture

**ThoughtQueue** is a macOS menu bar app (LSUIElement) for capturing text snippets and sending them to Claude Desktop. Swift + AppKit, no external dependencies.

### Core flow

1. User selects text in any app, hits a global hotkey
2. `HotkeyManager` (CGEventTap) fires, calls `CaptureService`
3. `CaptureService` simulates Cmd+C to grab selection, stores in SQLite via `DatabaseManager`
4. User later clicks "Open" on an entry
5. `ClaudeIntegration` activates Claude Desktop, simulates Cmd+Shift+O (new chat) then Cmd+V (paste)

### Key patterns

- **Singletons** for all services: `DatabaseManager.shared`, `CaptureService.shared`, `ClaudeIntegration.shared`, `PreferencesManager.shared`
- **NotificationCenter** with `.entriesDidChange` for UI synchronization across all views
- **Raw SQLite3 C API** (no ORM), database at `~/Library/Application Support/ThoughtQueue/thoughtqueue.db`
- **CGEvent** for both hotkey capture and keyboard simulation, requires Accessibility permission, app is non-sandboxed

### UI layers

- **Left-click menu bar icon**: `PopoverController` shows collapsible categories with entry previews and quick actions
- **Right-click menu bar icon**: Context menu with "Open ThoughtQueue" (full window), Preferences, Quit
- **MainWindowController**: NSSplitViewController with category sidebar + entries table + "Clear Completed"
- **NoteWindowController**: The single note window for creating, viewing, and editing a note (inline editable title + category dropdown, view/edit toggle). Used by "+ Add Note" and detailed capture alike.

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
