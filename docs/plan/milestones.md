# Milestones

Each milestone ends in something that runs. Decisions behind them are in
[`docs/adr/`](../adr/).

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
- Capture: new note from clipboard (hotkey, menu, Services, drag and drop);
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

## M4 — Preview, images, formatting, scripts

- Markdown preview (remote loads blocked), images as attachments with inline
  chips, Vision text recognition feeding search.
- Prettier in JavaScriptCore, SQL formatting.
- Boop-compatible scripts, bundled set plus a user folder.

## M5 — Sync and iOS

- Confirm the CloudKit encryption question in ADR 0002.
- `CKSyncEngine` sync of notes and attachments.
- iOS app: capture (share extension, paste), search, read, light editing.

## M6 — Mac App Store

- fastlane lanes, TestFlight for macOS and iOS, App Store submission.

## Later

- Folding.
- Command-line tool (`pbpaste | boopstash`, search from the terminal).
- On-device semantic search.
- Formatters compiled to WebAssembly.
