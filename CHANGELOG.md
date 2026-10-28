# Changelog

Notable changes, newest first. This project follows
[semantic versioning](https://semver.org); while the major version is 0,
breaking changes may land in a minor release.

## Unreleased

- A Mac app to stash buffers in: a list of notes, newest edit first, with a
  filter that matches anywhere inside words, a title/content scope and an
  edited-within choice (today, 7 or 30 days).
- An editor that leaves your text alone: no smart quotes, dashes or
  auto-pairing, ⌘V always pastes plain text, Tab and Shift-Tab indent, and
  key bindings follow VS Code (or JetBrains, or Emacs) with an optional
  Linux-habits layer and a VS Code-style `keybindings.json`.
- Paste as Markdown (⌥⇧⌘V) turns copied web pages, Slack or Google Docs into
  markdown.
- Capture from anywhere: File ▸ New Note from Clipboard (⌥⌘N), a global ⌃⌥⌘V,
  and Services ▸ Save to Boopstash. Password-manager items are never stored.
- Notes name themselves, with Apple's on-device model where available and
  from their first meaningful line otherwise; a title you type is kept.
- File ▸ Export All Notes… writes every note as a markdown file with its dates
  and source app in front matter.
- Project skeleton: Tuist project with `BoopstashCore` and a sandboxed macOS
  app, CI, and the first architecture decision records.
