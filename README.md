# ThoughtQueue

A macOS menu bar app that lets you capture text from any application and send it to [Claude Desktop](https://claude.ai/download) as a new conversation. Save ideas, code snippets, quotes, or anything else as you work -- then explore them with Claude when you're ready.

## Why

You're reading something interesting, debugging code, or researching a topic and you come across text you want to ask Claude about -- but not right now. ThoughtQueue lives in your menu bar and lets you grab that text with a hotkey, organize it into categories, and send it to Claude as a fresh conversation whenever you want.

## Features

- **Global hotkeys** -- capture selected text from any app without switching windows
- **Quick capture** -- one shortcut saves instantly, no interruption
- **Detailed capture** -- a second shortcut opens an overlay to edit the text and pick a category before saving
- **Add note** -- write a note manually with a hotkey or a `+ Add Note` button in the popover and main window
- **Edit entries** -- click `Edit` on any card in the main window to revise the text or change its category
- **Categories** -- organize entries however you want; create, rename, move between, or delete categories. New categories can also be created inline from the capture/edit dialog's dropdown
- **Claude Desktop integration** -- opens a new Claude chat and pastes the text automatically
- **Completion tracking** -- entries get a checkmark after being sent to Claude; bulk-clear completed entries
- **Local storage** -- everything stays on your machine in a SQLite database
- **Customizable hotkeys** -- change shortcuts in Preferences

## Requirements

- macOS 14.0+
- Xcode 16.0+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for building from source)
- [Claude Desktop](https://claude.ai/download) (for the "Open in Claude" feature)

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
| Quick capture | `Cmd+Shift+B` | Saves selected text instantly to "Uncategorized" |
| Detailed capture | `Cmd+Shift+Option+B` | Opens an overlay to edit text and choose a category |
| Add note | `Cmd+Shift+N` | Opens a blank dialog to type a new note and choose a category |

Select text in any app, hit the shortcut, and keep working. A toast confirms the capture. Add Note can also be triggered from the `+ Add Note` button in the menu-bar popover or the main window.

### Manage your queue

- **Left-click** the menu bar icon to open a popover with a searchable notes list and quick actions on each row (Open with, Copy note, Copy path, Delete)
- **Right-click** the menu bar icon for the full management window, preferences, or to quit

### Send to Claude

Click **Open** on any entry. ThoughtQueue will activate Claude Desktop, open a new chat, paste the text, and mark the entry as completed.

### Organize with categories

Create categories from the sidebar in the full management window or from the right-click context menu. Move entries between categories with the **Move** button. Deleting a category gives you the option to move its entries to Uncategorized or delete them.

### Clear completed entries

In the full management window, click **Clear Completed** to remove all entries that have already been sent to Claude.

### Change hotkeys

Right-click the menu bar icon > **Preferences**. Click a shortcut field and press your desired key combination.

## How it works

ThoughtQueue uses macOS Accessibility APIs (`CGEventTap`) to listen for global hotkeys and simulate keyboard input. Text capture works by simulating Cmd+C, reading the pasteboard, then restoring it. Claude integration triggers Claude Desktop's native shortcuts via keyboard simulation -- no API keys or network calls needed.

Entries are stored locally in a SQLite database at:

```
~/Library/Application Support/ThoughtQueue/thoughtqueue.db
```

## Running tests

```bash
./build.sh        # builds Debug by default
xcodebuild -project ThoughtQueue.xcodeproj -scheme ThoughtQueueTests test
```

## Tech stack

- Swift 5.9, AppKit (no SwiftUI)
- SQLite3 (C API, no ORM)
- CGEvent for hotkeys and keyboard simulation
- XcodeGen for project generation
- No external dependencies

## License

MIT
