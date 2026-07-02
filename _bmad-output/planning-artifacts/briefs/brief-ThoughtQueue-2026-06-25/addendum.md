# ThoughtQueue Brief: Addendum

Depth that belongs in downstream documents (PRD, architecture) but would bloat the brief.

## Existing codebase (reference only, to be archived)

The current ThoughtQueue is a macOS menu-bar app (LSUIElement), Swift + AppKit, no external deps. Patterns worth carrying forward into the greenfield build:

- **Menu-bar shell:** left-click popover with categories and quick actions, right-click context menu (Open / Preferences / Quit), and a full main window (split view: sidebar + table).
- **Capture:** global hotkey via CGEvent tap, simulate Cmd+C to grab the selection, then store. A floating detailed-capture panel near the cursor with editable text and category picker.
- **Claude integration:** activates Claude Desktop (`com.anthropic.claudefordesktop`), simulates Cmd+Shift+O (new chat) then Cmd+V (paste). Pure keyboard simulation, not APIs. Requires Accessibility permission, and the app is non-sandboxed.
- **What to drop:** the raw SQLite3 store (`~/Library/Application Support/ThoughtQueue/thoughtqueue.db`), replaced by the filesystem-as-truth model.

The "app+input" Open-with type generalizes the existing Claude integration: activate an app, then inject input (an `@{path}` reference or the pasted body) via the same CGEvent keyboard-sim approach.

## Local LLM research

Apple's **Foundation Models framework** (announced WWDC 2025, shipped with macOS 26) gives a Swift API to the on-device ~3B model behind Apple Intelligence:

- Free, on-device, offline, no account. Matches every ThoughtQueue principle.
- Strong at the exact tasks needed: summarization and entity extraction (titles), plus text understanding (categories).
- "Guided generation" via the `@Generable` macro returns structured Swift types directly, a clean fit for emitting a category from a constrained set.
- Constraints: requires macOS 26 and an Apple Intelligence-capable device. The ~3B model is small, which is the speed risk.
- Fallback if insufficient: Ollama or an MLX-based local model.

Sources:
- https://developer.apple.com/documentation/FoundationModels
- https://developer.apple.com/videos/play/wwdc2025/286/
- https://www.apple.com/newsroom/2025/09/apples-foundation-models-framework-unlocks-new-intelligent-app-experiences/

## Jobs To Be Done (detail)

- **Meeting todos:** "In a meeting, capture todo-list notes for later reference, so I can look things up and get people answers." Served by markdown's native checkboxes plus fast capture and title search, no bespoke todo feature.
- **Accreting a doc from fragments:** "When I see text I want to reference later or build into a spec/plan/document, capture it, so I can later find it and assemble it." Served by append-to-existing plus the working-document sink, no document-management machinery.

Design principle surfaced: specific jobs are served by general primitives (quick capture, plain markdown, folders, search, open-with), never by bolting on per-job modes.

## Rejected / reconsidered ideas

- **YAML frontmatter for metadata** (title/category/date inside the file) was proposed early, then rejected. It would clutter files and degrade external editing. Replaced by expressing all metadata through the filesystem (folder, filename, timestamp). This reversal is what makes the filesystem-as-truth philosophy internally consistent.

## Two-way sync: open design questions (for PRD/architecture)

- Behavior on external rename (does the app treat it as a title change?), move (category change), delete (remove from view), and concurrent edits (app open while editing in another tool).
- Whether to debounce or coalesce filesystem events, and how to avoid feedback loops between app writes and the folder watcher.

## Synthesis carried from brainstorm

- The "working document" default sink resolves the original tension: it delivers zero-decision capture and avoids the nameless-orphan-note landfill, because captures accrete into a known target.
- App-as-shell, filesystem-as-database, and "notes are the only durable thing" are one coherent architecture, not three features: radical portability.
- The breakthrough is open-with-as-context-handoff (the `@path` into Claude), not the basic launcher.
