# Milestones

Each milestone ends in something that runs. Decisions behind them are in
[`docs/adr/`](../adr/); what each release brought is in
[`CHANGELOG.md`](../../CHANGELOG.md).

| Milestone | Status |
|---|---|
| M0–M3 | Done; first release v0.1.0 |
| M4 — Preview, images, formatting, scripts | Done; v0.2.0 |
| M5 — Sync and iOS | Done; v0.3.0 |
| M6 — Mac App Store | Done; 0.3.0 in App Review (macOS and iOS) |
| v0.3.1 | On `main`, released after 0.3.0 is approved |
| M7 — Folding, command line, semantic search, more formatters | In progress |

Releases stay at most one version ahead of the App Store: while a version
is in review, work lands on `main` and waits.

## M0 — Skeleton

- OSS files: licence, changelog, contributing, security policy, code of
  conduct, issue and PR templates, dependabot.
- Tuist project pinned through mise: `BoopstashCore` (macOS + iOS, pure
  Foundation, unit-tested) and the `Boopstash` macOS app (sandboxed, empty
  window).
- CI: generate, test Core, build the app, compile Core for iOS.
- ADRs 0001–0005 and this plan.

## M1 — Editor spike

- The same test bench on three engines (ADR 0003 criteria).
- Outcome recorded as ADR 0006: TextKit 2 `NSTextView`. STTextView excluded on
  licence, CodeEditSourceEditor on forced quote pairing. The spike stays in
  `Spikes/EditorSpike/` as evidence, outside CI.

## M2 — Mac MVP

- Store: GRDB schema and migrations, FTS5 search, filter by last N days with
  title and/or content text.
- Capture: new note from clipboard (hotkey, menu, Services, drag and drop of
  text and text files);
  concealed/transient types refused; source app and time recorded.
- Titles: Foundation Models when available, rule-based fallback (first
  meaningful line, detected content type, source app, time).
- Editor: the chosen engine, no substitutions, Tab / Shift-Tab, keymap presets
  (VS Code default, JetBrains, Emacs) with the Linux-habits toggle and
  `keybindings.json` overrides.
- Paste: plain ⌘V; Paste as Markdown (⌥⇧⌘V).
- Highlighting for 20 common languages (incremental tree-sitter, off the main
  thread), with a per-note language menu. Native JSON / XML / plist formatting moved to M4 with the other
  formatters.
- Export as a folder of `.md` files plus attachments.
- Help: how to turn on Spotlight's clipboard history.

## M3 — First release (0.1) via Homebrew

- Developer ID signing, notarization, stapling in `release.yml`.
- Cask template in `packaging/homebrew/`, rendered into
  `lemehmet/homebrew-boopstash` with a deploy key.
- Repository goes public around here.

## M4 — Preview, images, formatting, scripts (done, v0.2.0)

- Markdown preview, drawn natively (remote loads blocked), images as
  attachments with inline chips, Vision text recognition feeding search.
- Format Document: JSON and XML natively; Prettier and sql-formatter in a
  sandboxed XPC script service (ADR 0007).
- Boop-compatible scripts, bundled set plus a user folder.

## M5 — Sync and iOS (done, v0.3.0)

- CloudKit encryption settled in ADR 0002: every field encrypted, end to end
  with Advanced Data Protection.
- `CKSyncEngine` sync of notes and attachments, off until turned on; iCloud
  entitlements only in provisioned builds (ADR 0008).
- iOS app: list, search, read, light editing, Markdown preview, New Note from
  Clipboard, and a share extension writing into an App Group store.

## M6 — Mac App Store (done, 0.3.0 in review)

- fastlane lanes with match signing; TestFlight for macOS and iOS; App Store
  submission of one universal-purchase app, with screenshots from a demo
  mode of made-up notes.
- Privacy policy and support pages on GitHub Pages.

## v0.3.1 (on `main`)

- The language menu shows the language in use, marked when detected.
- The preview renders Markdown only, with a placeholder for other notes.
- Toolbar buttons for Paste as Markdown, Run Script, Show Preview and Preview
  Beside the Editor.
- Settings screenshots for the App Store.

## M7 — Folding, command line, semantic search, more formatters

- Folding by structure: braces, elements, Markdown sections, indentation;
  view-only, with a gutter and commands (#155).
- A bundled, sandboxed `boopstash` command: capture from stdin, search, list
  and show, sharing the store through an App Group (#156, ADR 0009).
- On-device semantic search with NaturalLanguage sentence embeddings,
  alongside full-text search, never synced (#157).
- More formatters built as WebAssembly in the script service, for
  languages Prettier lacks (#158, ADR 0010).

## Later

Nothing scheduled.
