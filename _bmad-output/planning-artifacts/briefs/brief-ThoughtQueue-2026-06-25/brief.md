---
title: "Product Brief: ThoughtQueue"
status: draft
created: 2026-06-25
updated: 2026-06-25
---

# Product Brief: ThoughtQueue

## Executive Summary

ThoughtQueue is a fast, personal, macOS quick-notes app that is really just a thin shell over a folder of plain markdown files you fully own. Today it's a menu-bar tool for capturing text and firing it into Claude Desktop. This brief covers its evolution into a daily-driver notes app where the filesystem is the database and the app is only a convenient window onto it.

The wedge is the empty middle between the two kinds of notes apps that exist. There are the ones that are too much (Notion: heavy, opinionated, a knowledge base whether you wanted one or not) and the ones that aren't flexible enough (Apple Notes: locked-in, you don't really own your data). ThoughtQueue sits in the gap: minimal, flexible, and built on plain `.md` files in a folder you choose. Its standout move is context handoff. You can open any note as an `@path` reference straight into Claude or another AI tool, so the note doesn't just get launched, it arrives as context.

This is a personal passion project and a daily driver for its author. Success is simple and honest: it gets used every day and replaces the scattered mix of Apple Notes and scratch files it's meant to kill.

## The Problem

Capturing a quick thought should be frictionless, and the result should be yours forever. Neither is true today. Heavyweight apps make you think about databases, blocks, and structure before you can jot a line. Lightweight apps trap your notes in a proprietary store you can't open, grep, or move. And the moment a notes app tries to become a knowledge base, it stops serving quick capture and starts serving an org.

The author's real moments make this concrete: grabbing todo notes mid-meeting to follow up on later, and collecting stray bits of text over days to accrete into a spec or plan. Both need instant capture and durable, portable storage, and neither needs document-management machinery.

## The Solution

A menu-bar app that captures text in one motion and writes it as a plain markdown file into a folder you control. Organization lives in the filesystem itself, not hidden in a database: **category = folder, title = filename, date = filesystem timestamp.** No proprietary metadata, no YAML frontmatter, nothing that makes a note less than fully usable in any text editor or in Finder.

Because the folder is the source of truth, the app and the filesystem stay in sync both ways. Edit or move a file in another tool and the app reflects it; act in the app and the folder updates. Capture can spin up a new note or append to one you're already building, with a designated "working document" as the default sink so most captures need zero decisions. Retrieval is fuzzy search across titles. And "Open with..." turns the app into a launchpad that hands a note off with its context to Claude, Zed, or any tool you define.

## What Makes This Different

- **You own the files, completely.** Plain `.md` in a folder you pick. If the app vanished tomorrow, you'd lose only the convenience, never a single note or its organization.
- **Context handoff, not just launching.** Opening a note as an `@path` reference into Claude (so the session can read the file) is what makes this more than a notes app, while keeping it minimal.
- **Disciplined smallness.** It refuses to become a knowledge base or corp tool. The honest moat is restraint plus execution, not technical lock-in.

## Who This Serves

One user to start: the author, a developer who lives in the menu bar and in AI tooling, wants zero-friction capture, and wants the resulting notes to be plain files he can pipe into Claude, edit in Zed, or grep from a terminal. Success for him is daily reliance and the quiet death of his Apple Notes and scratch-file habit.

## Success Criteria

- **Primary:** the author uses it every day and stops reaching for Apple Notes and ad-hoc scratch files.
- Capture feels instant, with no perceptible wait between the hotkey and the note being saved.
- Notes stay fully usable with the app closed (readable, editable, greppable, movable from Finder or an editor).
- The Claude `@path` handoff is reliable enough to become a habit, not a party trick.

## Scope

**In (MVP)**
- Configurable markdown store folder; folder = category, filename = title, filesystem timestamp = date; no frontmatter.
- Capture from selected text (right-click context menu + global hotkey) and menu-bar quick capture.
- New-note vs. append-to-existing with a popup picker, plus a designated "working document" default sink.
- Two-way live sync with the store folder.
- Fuzzy search across note titles.
- "Open with...": command type (e.g. `zed {path}`) and app+input type (activate app, simulate `@{path}` reference or paste body), with the Claude `@path` context handoff as the flagship.
- Click-behavior setting: run open command, render markdown in-app, or edit raw in-app.
- Local-LLM auto-title and auto-categorize via Apple's Foundation Models framework, with a transient, editable review toast under the menu-bar icon. It runs async and never blocks capture.

**Later**
- Additional "Open with..." destinations (Gemini and other AI tools).

**Explicitly out (anti-scope)**
- Anything that turns it into a knowledge base, wiki, or document-management system.
- Accounts, sync services, payments, or any SaaS dependency.
- App-owned data or clutter in the store folder beyond the notes themselves.

## Technical Notes

- **Greenfield rebuild.** Archive the current ThoughtQueue codebase and use it as reference only. Build fresh with no database; the filesystem is the store. Reuse proven patterns (menu-bar/LSUIElement shell, CGEvent capture, Claude keyboard-simulation integration), not the SQLite layer.
- **macOS only**, single user, no deadline.
- **Local LLM:** Apple's Foundation Models framework (macOS 26) is the intended engine. It's free, on-device, private, Swift-native, with guided generation for structured category output. It requires macOS 26 and an Apple Intelligence-capable device. Ollama/MLX is the fallback if the built-in model proves too limited.

## Key Risks & Open Questions

- **Local-LLM latency** is the top risk, and it's now in the MVP. The design must keep capture instant by running inference fully async: the note saves immediately, the model titles and categorizes in the background, and the editable review toast surfaces the result after the fact. Capture must never wait on the model.
- **macOS 26 dependency.** Auto-intelligence, and therefore the full MVP, requires macOS 26 and an Apple Intelligence-capable device. The non-AI capture and storage core should degrade gracefully (a sensible default title and category) on unsupported setups so the app still works without the model.
- **Two-way sync edge cases** (external moves, deletes, renames, conflicting edits) need defined behavior, flagged for the design phase.
- **App+input "Open with..." reliability** across arbitrary apps depends on keyboard simulation, which is inherently brittle. The command type is the safer default, and Claude is the proven case.

## Vision

A notes tool you stop noticing, because it never gets in the way and never holds your data hostage. A folder of clean markdown that outlives the app, plugs into whatever AI tooling comes next through simple context handoff, and stays stubbornly personal while everything else in the category bloats into platforms.
