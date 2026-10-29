# Changelog

Notable changes, newest first. This project follows
[semantic versioning](https://semver.org); while the major version is 0,
breaking changes may land in a minor release.

## Unreleased

- Scripts ▸ Run Script… (⌘B) runs Boop's scripts on the selection, or each
  part of a multiple selection, or the whole note: Base64, URL and HTML
  encoding, hashes, case changes, sorting, JSON and YAML conversion and more,
  71 in all. Run Last Script is ⇧⌘B. Scripts run in their own sandboxed
  process with no network or file access, and one that runs longer than two
  seconds is stopped.

## v0.1.1 — 2026-10-28

### New

- The app is now spelled BoopStash: BoopStash.app, its menus and the
  Services item "Save to BoopStash". Your notes and settings carry over, as
  the bundle identifier is unchanged; `brew upgrade` replaces Boopstash.app.
- BoopStash has its own icon.
- Settings ▸ Editor: the editor's font and size, and a theme for light and
  dark appearance from Solarized, GitHub, One, Gruvbox, Dracula and Nord, or
  the system's colours. A theme sets the background, text, selection and
  highlighting together. Settings are now in General, Editor and Keyboard tabs.

### Fixes

- The app reports its real version (0.1.0 called itself 1.0 in About and
  Finder).
- Line commands (move, duplicate, delete line) keep each line's own ending,
  including Windows CRLF.
- Paste as Markdown: link addresses with spaces, parentheses, backslashes or
  control characters no longer break the link; brackets in link text are
  escaped; spaces at a link's edges stay in the sentence; and the command is
  available only while a note's editor has focus.
- Dropped files: a file that grows, or comes from a pipe, is read in full up
  to the 5 MB limit and no further, and a drop is credited to the app it came
  from at the moment of the drop.
- Titles: indented JSON is still recognised as JSON, a failed Apple
  Intelligence title is retried rather than recorded, and turning that
  setting off discards replies still on their way. Notes that start with a
  very long run of blank lines are titled without reading all of them.
- Export: titles with characters YAML cannot hold as written (such as
  U+FFFE) are escaped in the front matter.
- A save from ⌃⌥⌘V that fails brings the window forward so the reason is
  visible.

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
