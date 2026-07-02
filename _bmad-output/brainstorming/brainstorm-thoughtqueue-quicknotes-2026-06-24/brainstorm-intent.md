# ThoughtQueue — Brainstorm Intent

## Product Intent
Evolve ThoughtQueue from a capture-and-send-to-Claude menu-bar app into a fast, daily-driver personal notes app that is a thin shell over a folder of plain markdown files you fully own.

## Problem & Positioning
Every notes app is either "too much" (Notion: heavy, opinionated, knowledge-base) or "not flexible enough" (Apple Notes: you don't own your data). The wedge is the gap between them: minimal + flexible + you fully own your data as plain local files. The standout differentiator is context-handoff (open a note as an `@path` reference into Claude/AI tools), which makes it more than a notes app while staying minimal.

## Guiding Principles / Non-Negotiables
- **Own your files.** Notes are plain `.md` files in a local folder, fully editable in any text editor outside the app.
- **Personal, not corporate.** Stays a quick personal note app; never drifts into knowledge-base / document-management / corp tooling. Scope creep = purpose creep.
- **No accounts, no money.** Say NO to any feature requiring an account or payment. Free, account-less, local-only, no SaaS dependency.
- **Notes are the only durable truth.** The store folder contains only notes — no app clutter. Configs, search index, LLM, and auto-smarts are disposable helpers.
- **App is a shell over the filesystem.** The filesystem is the source of truth; the app creates/updates/organizes/accesses. If the app dies, only convenience (quick access) is lost, never content or organization.

## Architecture / Data Model
- Plain `.md` files in a user-chosen folder. Configurable store location.
- **Category = folder. Title = filename. Date = filesystem created/modified timestamp.** No DB needed for metadata.
- **No YAML frontmatter** — keep files clean and portable for external editing. Metadata lives in the folder/file structure, not inside files.
- **Two-way live sync:** the app watches the store folder and live-reflects external changes (edits, moves, deletes) made by other tools.

## Feature Set

### Capture
- Right-click context-menu action + global key command to create a note from selected text (evolves existing CGEvent capture).
- Quick-capture from the menu-bar dropdown.
- Capture supports two modes: **create a new standalone note**, OR **append captured text onto an existing note** you're building.
- Append-target selection via a popup picker.
- A user-designated **"working document"** acts as the default catch-all sink: all captures land there unless a different target is specified (zero-decision capture without orphan-note landfill).

### Auto-intelligence (local, private)
- Auto-generate a title for each note (no manual typing).
- Auto-organize notes into categories.
- Powered by a **small local LLM** (private, offline).
- After capture, a **transient toast** under the menu-bar icon shows the auto title + category with an Edit button; auto-dismisses after a user-configurable timeout.

### Retrieval
- Fuzzy search across all note titles.

### Click behavior (user setting)
Default click action on a note is one of: (a) run the default open command, (b) view/render markdown in-app, (c) edit raw text in-app.

### Open-with (context handoff)
Two action types:
1. **Command type** — run a shell command with the path as input, e.g. `zed {path}`.
2. **App+input type** — activate an app, then inject input via simulation (reuses existing CGEvent keyboard-sim): either an `@{path}` reference or the full pasted document body.

Destinations: Claude, Gemini (and other AI tools), Zed. **Standout:** open Claude pre-loaded with `@/path/note.md` so the session can read the file directly — handoff of context, not just a launcher.

## Jobs To Be Done (grounding)
- **Meeting todos:** "In a meeting, capture todo-list notes for later reference, so I can look things up and get people answers." Implies markdown checkboxes/todo items + easy retrieval of action items.
- **Accreting a doc from fragments:** "When I see text I want to reference later or build into a spec/plan/document, capture it, so I can later find it and assemble it into a document." Served by append + working-document sink, without bespoke doc-management features.

## MVP vs Later
**MVP**
- Configurable markdown store folder; folder=category, filename=title, filesystem timestamp=date; no frontmatter.
- Capture from selection (right-click + hotkey) and menu-bar quick capture.
- New-note vs append-to-existing with picker; designated working-document default sink.
- Two-way live sync with the store folder.
- Fuzzy search across titles.
- Open-with: command type and app+input type; Claude `@path` context handoff.
- Click-behavior setting (open / render / edit-raw).

**Later**
- Local-LLM auto-title and auto-categorize with transient review toast.
- Additional open-with destinations (Gemini and other AI tools).
