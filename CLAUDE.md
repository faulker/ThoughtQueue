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
- **Raw SQLite3 C API** (no ORM) — database at `~/Library/Application Support/ThoughtQueue/thoughtqueue.db`
- **CGEvent** for both hotkey capture and keyboard simulation — requires Accessibility permission, app is non-sandboxed

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

<!-- rtk-instructions v2 -->
# RTK (Rust Token Killer) - Token-Optimized Commands

## Golden Rule

**Always prefix commands with `rtk`**. If RTK has a dedicated filter, it uses it. If not, it passes through unchanged. This means RTK is always safe to use.

**Important**: Even in command chains with `&&`, use `rtk`:
```bash
# ❌ Wrong
git add . && git commit -m "msg" && git push

# ✅ Correct
rtk git add . && rtk git commit -m "msg" && rtk git push
```

## RTK Commands by Workflow

### Build & Compile (80-90% savings)
```bash
rtk cargo build         # Cargo build output
rtk cargo check         # Cargo check output
rtk cargo clippy        # Clippy warnings grouped by file (80%)
rtk tsc                 # TypeScript errors grouped by file/code (83%)
rtk lint                # ESLint/Biome violations grouped (84%)
rtk prettier --check    # Files needing format only (70%)
rtk next build          # Next.js build with route metrics (87%)
```

### Test (60-99% savings)
```bash
rtk cargo test          # Cargo test failures only (90%)
rtk go test             # Go test failures only (90%)
rtk jest                # Jest failures only (99.5%)
rtk vitest              # Vitest failures only (99.5%)
rtk playwright test     # Playwright failures only (94%)
rtk pytest              # Python test failures only (90%)
rtk rake test           # Ruby test failures only (90%)
rtk rspec               # RSpec test failures only (60%)
rtk test <cmd>          # Generic test wrapper - failures only
```

### Git (59-80% savings)
```bash
rtk git status          # Compact status
rtk git log             # Compact log (works with all git flags)
rtk git diff            # Compact diff (80%)
rtk git show            # Compact show (80%)
rtk git add             # Ultra-compact confirmations (59%)
rtk git commit          # Ultra-compact confirmations (59%)
rtk git push            # Ultra-compact confirmations
rtk git pull            # Ultra-compact confirmations
rtk git branch          # Compact branch list
rtk git fetch           # Compact fetch
rtk git stash           # Compact stash
rtk git worktree        # Compact worktree
```

Note: Git passthrough works for ALL subcommands, even those not explicitly listed.

### GitHub (26-87% savings)
```bash
rtk gh pr view <num>    # Compact PR view (87%)
rtk gh pr checks        # Compact PR checks (79%)
rtk gh run list         # Compact workflow runs (82%)
rtk gh issue list       # Compact issue list (80%)
rtk gh api              # Compact API responses (26%)
```

### JavaScript/TypeScript Tooling (70-90% savings)
```bash
rtk pnpm list           # Compact dependency tree (70%)
rtk pnpm outdated       # Compact outdated packages (80%)
rtk pnpm install        # Compact install output (90%)
rtk npm run <script>    # Compact npm script output
rtk npx <cmd>           # Compact npx command output
rtk prisma              # Prisma without ASCII art (88%)
```

### Files & Search (60-75% savings)
```bash
rtk ls <path>           # Tree format, compact (65%)
rtk read <file>         # Code reading with filtering (60%)
rtk grep <pattern>      # Search grouped by file (75%). Format flags (-c, -l, -L, -o, -Z) run raw.
rtk find <pattern>      # Find grouped by directory (70%)
```

### Analysis & Debug (70-90% savings)
```bash
rtk err <cmd>           # Filter errors only from any command
rtk log <file>          # Deduplicated logs with counts
rtk json <file>         # JSON structure without values
rtk deps                # Dependency overview
rtk env                 # Environment variables compact
rtk summary <cmd>       # Smart summary of command output
rtk diff                # Ultra-compact diffs
```

### Infrastructure (85% savings)
```bash
rtk docker ps           # Compact container list
rtk docker images       # Compact image list
rtk docker logs <c>     # Deduplicated logs
rtk kubectl get         # Compact resource list
rtk kubectl logs        # Deduplicated pod logs
```

### Network (65-70% savings)
```bash
rtk curl <url>          # Compact HTTP responses (70%)
rtk wget <url>          # Compact download output (65%)
```

### Meta Commands
```bash
rtk gain                # View token savings statistics
rtk gain --history      # View command history with savings
rtk discover            # Analyze Claude Code sessions for missed RTK usage
rtk proxy <cmd>         # Run command without filtering (for debugging)
rtk init                # Add RTK instructions to CLAUDE.md
rtk init --global       # Add RTK to ~/.claude/CLAUDE.md
```

## Token Savings Overview

| Category | Commands | Typical Savings |
|----------|----------|-----------------|
| Tests | vitest, playwright, cargo test | 90-99% |
| Build | next, tsc, lint, prettier | 70-87% |
| Git | status, log, diff, add, commit | 59-80% |
| GitHub | gh pr, gh run, gh issue | 26-87% |
| Package Managers | pnpm, npm, npx | 70-90% |
| Files | ls, read, grep, find | 60-75% |
| Infrastructure | docker, kubectl | 85% |
| Network | curl, wget | 65-70% |

Overall average: **60-90% token reduction** on common development operations.
<!-- /rtk-instructions -->