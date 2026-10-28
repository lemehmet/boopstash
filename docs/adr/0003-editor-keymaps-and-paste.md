# ADR 0003 — Editor behaviour: keymap presets, no substitutions, plain paste

- **Status:** Accepted (2026-10-28); the text engine is chosen by the spike in
  milestone 1 and recorded in a follow-up ADR.
- **Deciders:** boopstash maintainers

## Context

Boop's editor is the main thing this project is reacting to. In daily use, and
especially for someone who also works on Linux desktops:

- It auto-closes quotes and brackets, which fights anyone pasting or typing code.
- Cursor movement follows AppKit's defaults: Home/End scroll the document
  rather than moving to the start or end of the line.
- Tab does not indent a selection, and Shift-Tab does not unindent.

The editor is a source editor for markdown and code. Boopstash is not trying to
be a rich-text or full markdown editor.

## Decision

- **Every automatic substitution is off and cannot be turned on:** quote and
  bracket pairing, smart quotes, smart dashes, text replacement, autocorrect,
  automatic link detection, spelling correction while typing. Spell-check
  underlining may stay as a preference, off by default.
- **Key handling is ours.** Actions (move to line start, delete word, indent
  lines…) are bound to key combinations through a preset table. Presets:
  **VS Code (default)**, **JetBrains**, **Emacs**. User overrides live in a
  `keybindings.json` in the same spirit as VS Code's.
- **A "Linux habits" toggle** layers over any preset: Home/End stay on the
  line, Ctrl+←/→ move by word. Swapping Ctrl and Cmd is out of scope; that
  belongs in a system-wide remapper.
- **No vi mode.** Dropped: modal editing is a different editor, not a preset.
- **Tab / Shift-Tab indent and unindent** the selected lines, or the current
  line when nothing is selected. Indent width is a preference (default four
  spaces, or a tab).
- **Paste:**
  - **⌘V always pastes plain text.** The body is markdown source, so there is no
    target style to match. An image on the pasteboard becomes an attachment.
  - **⌥⇧⌘V, Paste as Markdown,** converts the pasteboard's HTML or RTF into
    markdown (links, emphasis, lists, headings, tables, code). The conversion
    must not load remote resources, which rules out
    `NSAttributedString(html:)`; it is a pure function in Core with tests.
- **Folding is deferred** but is a selection criterion for the engine:
  structural ranges from tree-sitter for code, headings for markdown.

## Engine spike criteria (milestone 1)

Each candidate — a raw TextKit 2 `NSTextView`, STTextView, CodeEditSourceEditor —
gets the same small test bench, and the choice goes to whichever passes, not
whichever has the best README:

1. Hide and show a line range with correct caret movement, selection and copy
   across it (folding).
2. Complete control over key handling, including chords the system normally
   claims.
3. No automatic substitution can leak through.
4. Tab / Shift-Tab over a multi-line selection, undoable as one step.
5. Tree-sitter highlighting of a 1 MB file without visible typing lag.
6. An inline chip for an image attachment.

iOS is capture, search and read with light editing, so the Mac engine does not
need to run there.

## Consequences

- Keymap presets are data, tested in Core: a table from action to key
  combination, with a resolver that applies the Linux layer and user overrides.
- Rich text never enters the store.
