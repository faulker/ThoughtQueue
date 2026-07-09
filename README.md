# ThoughtQueue

A macOS menu bar app for capturing quick notes from anywhere and doing something useful with them right away -- copy them, or run them straight into whatever app or command you use next. Notes are plain markdown files on disk, not locked in a database or tied to any one destination.

## Why

You're reading something, debugging code, or thinking out loud and want to jot it down without breaking flow. ThoughtQueue lives in your menu bar: grab text with a hotkey (or just type a note), file it into a category, and when you're ready, copy it or fire it off to an editor, a CLI tool, or an app like Claude Desktop with one click.

## Features

- **Global hotkeys** -- capture selected text from any app without switching windows
- **Quick capture** -- one shortcut saves instantly, no interruption
- **Detailed capture** -- a second shortcut opens the note editor pre-filled with the selection so you can adjust it before saving
- **Add note** -- write a note from scratch via the `+ Add Note` button in the popover or main window
- **Note editor** -- a single window per note with a view/edit toggle: markdown renders by default, click or start typing to edit the raw text, with autosave and full undo/redo (Cmd+Z / Cmd+Shift+Z)
- **Copy, don't just open** -- one click to copy a note's full body or its file path straight to the clipboard, right from its row
- **Run notes anywhere** -- configurable "Open With" destinations: run a shell command against the note's file (open it in an editor, hand it to a CLI tool, whatever `{path}` template you want), or paste it into an app like Claude Desktop. Comes with Claude and Zed presets; add, edit, or remove your own in Preferences
- **Categories** -- organize notes however you want; create, rename, move between, or delete categories, with folders on disk to match. New categories can also be created inline from any category dropdown
- **Working document** -- optionally designate one note as the default sink so quick captures append to it instead of creating a new file each time
- **On-device auto-title & auto-category** -- optional, macOS 26+: suggests a title and category for each capture via Apple's on-device model, with a review toast to accept, tweak, or dismiss
- **Local, plain-text storage** -- notes are `.md` files in a folder you choose; no database, so they're greppable and easy to sync or back up yourself
- **Customizable hotkeys** -- change shortcuts in Preferences

## Requirements

- macOS 14.0+ (macOS 26+ for optional on-device auto-title/auto-category)
- Xcode 16.0+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for building from source)
- Nothing else is required out of the box -- [Claude Desktop](https://claude.ai/download) and [Zed](https://zed.dev) are just the built-in "Open With" presets; wire up any app or command you actually use instead

## Install

```bash
brew install xcodegen  # if you don't have it

git clone <repo-url>
cd ThoughtQueue
```

### Debug build (local development)

Unsigned, fastest, what you want while iterating:

```bash
./build.sh              # defaults to Debug
# or: ./build.sh Debug
open build/Build/Products/Debug/ThoughtQueue.app
```

### Production build (signed for distribution)

Signs with your **Developer ID Application** certificate and enables the hardened runtime, producing an app you can distribute outside the Mac App Store.

Prerequisites (one-time):

1. Apple Developer account.
2. Install your `Developer ID Application` certificate into your login keychain. Easiest path: Xcode → Settings → Accounts → your Apple ID → **Manage Certificates** → `+` → **Developer ID Application**.
3. Verify it shows up:

   ```bash
   security find-identity -v -p codesigning
   ```

   You should see at least one line containing `"Developer ID Application: Your Name (TEAMID)"`.

Then build:

```bash
./build.sh Release
open build/Build/Products/Release/ThoughtQueue.app
```

The script auto-detects the first `Developer ID Application` identity in your keychain, extracts your Team ID, signs the app with hardened runtime and a secure timestamp, then runs `codesign --verify` to confirm the signature is valid. If no identity is found, the build fails with a clear error.

The output binary is signed but **not notarized**. For personal use or distribution to users who can right-click → Open, signing is enough. For frictionless distribution, you'll need to notarize separately with `xcrun notarytool` and `xcrun stapler`.

### Or use Xcode directly

```bash
xcodegen generate
open ThoughtQueue.xcodeproj
# Build and run with Cmd+R
```

To keep ThoughtQueue available, drag `ThoughtQueue.app` to your Applications folder.

## Setup

On first launch, ThoughtQueue appears in your menu bar with a `"` icon. macOS will prompt you to grant **Accessibility permission** (System Settings > Privacy & Security > Accessibility). This is required for global hotkeys and text capture to work.

## Usage

### Capture text

| Action | Default Shortcut | What happens |
|---|---|---|
| Quick capture | `Cmd+Shift+B` | Saves selected text instantly (to the working document if one is set, otherwise a new note) |
| Detailed capture | `Cmd+Shift+Option+B` | Opens the note editor pre-filled with the selection so you can adjust text and category before saving |

Select text in any app, hit the shortcut, and keep working. A toast confirms the capture. Use the `+ Add Note` button in the menu-bar popover or the main window to start a note from scratch instead.

### Manage your notes

- **Left-click** the menu bar icon to open a popover with a searchable notes list and quick actions on each row (Open with, Move to category, Copy note, Copy path, Delete)
- **Right-click** the menu bar icon for the full management window, preferences, or to quit

### Copy a note

Click the **Copy note** icon on any row to copy its full body, or **Copy path** to copy its absolute file path -- no need to open the note first.

### Run a note anywhere

Click **Open With** (or the arrow icon on a row) to send a note to one of your configured destinations. Two kinds of destination:

- **Command** -- runs a shell command with the note's file path substituted in, e.g. `zed {path}` or `code {path}`. Point it at any editor or CLI tool.
- **App input** -- activates an app and either types `@<path>` (file-reference style, what the Claude preset uses) or pastes the note's full body.

Configure destinations in **Preferences > Open With actions**: add, edit, delete, or reset to the built-in Claude/Zed presets.

### Edit a note

Every note opens in a single view/edit window. It opens read-only with markdown rendered; click, double-click, or start typing (configurable in Preferences) to switch to raw-text edit mode. Edits autosave on save/close, and the usual Cmd+Z / Cmd+Shift+Z undo/redo works while editing.

### Organize with categories

Create categories from the sidebar in the full management window. To move a note into a different category, use the category dropdown in the note's detail pane (or its own window), right-click a note in the list and pick **Move to Category**, or use the tag button on a note row in the menu bar dropdown. Each of those also offers **New Category** to create and move in one step.

### Change hotkeys

Right-click the menu bar icon > **Preferences**. Click a shortcut field and press your desired key combination.

## How it works

ThoughtQueue uses macOS Accessibility APIs (`CGEventTap`) to listen for global hotkeys and simulate keyboard input. Text capture works by simulating Cmd+C, reading the pasteboard, then restoring it. "Open With" destinations either shell out via `Process` (command type) or activate the target app and simulate keystrokes to paste (app-input type) -- no API keys or network calls needed either way.

Notes are plain `.md` files in a folder you choose (default `~/Documents/ThoughtQueue`); categories are just subfolders. There's no database -- the filesystem is the source of truth, so notes are portable and easy to sync or back up yourself.

## Running tests

```bash
./build.sh        # builds Debug by default
xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueueTests test
```

## Tech stack

- Swift 5.9, AppKit (no SwiftUI)
- Filesystem-backed note store (plain `.md` files, no database)
- CGEvent for hotkeys and keyboard simulation
- Apple FoundationModels (optional, macOS 26+) for on-device auto-title/auto-category
- XcodeGen for project generation
- No external dependencies

## License

MIT
