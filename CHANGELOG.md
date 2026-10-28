# Changelog

Notable changes, newest first. This project follows
[semantic versioning](https://semver.org); while the major version is 0,
breaking changes may land in a minor release.

## Unreleased

- The app reports its real version (0.1.0 called itself 1.0 in About
  Boopstash and Finder).

## v0.1.0 — 2026-10-28

The first release: a scratch pad for macOS that keeps what you paste.

### Install

- `brew install --cask lemehmet/boopstash/boopstash`, or the `.zip` from the
  release. Signed with Developer ID and notarized; universal (Apple Silicon
  and Intel); macOS 26 or newer.

### Notes

- A list of notes, newest edit first, with a filter that matches anywhere
  inside words, a title/content scope and an edited-within choice (today, 7
  or 30 days).
- Notes name themselves, with Apple's on-device model where available and
  from their first meaningful line otherwise; a title you type is kept.
- File ▸ Export All Notes… writes every note as a markdown file with its dates
  and source app in front matter.

### Editing

- An editor that leaves your text alone: no smart quotes, dashes or
  auto-pairing, ⌘V always pastes plain text, Tab and Shift-Tab indent, and
  key bindings follow VS Code (or JetBrains, or Emacs) with an optional
  Linux-habits layer and a VS Code-style `keybindings.json`.
- Syntax highlighting for JSON, YAML, TOML, XML, HTML, CSS, Markdown, SQL,
  JavaScript, TypeScript, Python, Ruby, shell, Go, Rust, C, C++, Java, Swift
  and diffs, picked from the note's content and kept up as you type. The
  toolbar's language menu forces a language, or plain text, for a note.
- Paste as Markdown (⌥⇧⌘V) turns copied web pages, Slack or Google Docs into
  markdown.

### Capture

- File ▸ New Note from Clipboard (⌥⌘N), a global ⌃⌥⌘V from any app,
  Services ▸ Save to Boopstash, and dropping text or a text file on the list.
- Password-manager and transient clipboard items are never stored, by any of
  these or by pasting into a note.
