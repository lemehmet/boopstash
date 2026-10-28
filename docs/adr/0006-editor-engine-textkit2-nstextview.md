# ADR 0006 — Editor engine: TextKit 2 `NSTextView`

- **Status:** Proposed (2026-10-28); becomes Accepted after the hands-on check
  below
- **Deciders:** boopstash maintainers
- **Evidence:** `Spikes/EditorSpike/` (its own Tuist project; not built by CI)

## Context

ADR 0003 set six criteria for the Mac editor engine and three candidates.
Two gates were added before the bench: a licence the app can ship under
(Apache-2.0, and the Mac App Store), and a maintained upstream.

## Candidates excluded before the bench

- **STTextView: licence.** GPLv3, or a paid commercial licence. GPLv3 code
  would make the whole app GPLv3 (Apache-2.0 → GPLv3 is one-way), and GPL is
  in conflict with the App Store's terms of use.
- **CodeEditSourceEditor (0.15.2): criterion 3, and maintenance.** It always
  auto-pairs `{ [ ( " '` through TextFormation filters built in
  `TextViewController.setUpTextFormation()`. The filter list is `internal`
  and `TextViewController` is `public`, not `open`, so the pairing cannot be
  switched off or overridden without forking. Its default branch has had no
  merge since 2025-12-31, with community PRs open since mid-2026. Forking a
  dormant editor to remove the one behaviour this project exists to remove is
  owning it. (It does ship folding, since 0.15.2.)

## Bench results: TextKit 2 `NSTextView` subclass

Ten checks in `Spikes/EditorSpike/Tests/SpikeChecks.swift`, all passing on
macOS 26.7 / Xcode 27.1. Each check that could pass vacuously has a control: a
stock `NSTextView` given the same input must show the behaviour being
removed.

| # | Criterion | Result |
|---|---|---|
| 1 | Folding | Pass. Hiding paragraphs through `NSTextContentManagerDelegate.textContentManager(_:shouldEnumerate:options:)` removes their layout fragments; ↓ from the heading lands on the line after the fold and ↑ returns; copying across the fold carries the hidden text. |
| 2 | Key handling | Pass. A chord table in `keyDown` / `performKeyEquivalent` takes Home/End (control: stock view leaves the caret), ⇧⌥↓ duplicate line, and ⌃⌘Space before the main menu's Emoji & Symbols item sees it. |
| 3 | No substitutions | Pass as far as automation reaches; real-keyboard typing is the hands-on check. No quote, dash, replacement, correction, link, spelling or grammar bit in `enabledTextCheckingTypes`; inline predictions, math completion and Writing Tools off; Edit ▸ Substitutions toggles refused and greyed out. |
| 4 | Tab / Shift-Tab | Pass. Multi-line selection indents and unindents, undone in one step; Tab without a multi-line selection inserts the indent unit at the caret. |
| 5 | 1 MB highlighting | Pass. 1 MB of JSON, 169k highlight ranges. Release build: full tree-sitter parse plus highlight query 247 ms (the worst case; the app parses incrementally, off the main thread), viewport paint 7.5 ms, keystroke plus viewport layout 11.7 ms (without re-highlighting). |
| 6 | Inline image chip | Pass. An `NSTextAttachment` lays out inline at its image's height, and the view stays on TextKit 2. |

## Decision

- **The Mac editor is a TextKit 2 `NSTextView` subclass we own.** No editor
  framework dependency.
- **Highlighting: SwiftTreeSitter with per-language grammar packages,** painted
  as TextKit 2 rendering attributes on the viewport only, so storage, undo and
  change notifications are never touched by colouring. Neon (ChimeHQ, BSD) is
  the reference for incremental, viewport-driven highlighting; whether to
  depend on it or write the small piece we need is decided when highlighting
  lands. Its `main` currently tracks SwiftTreeSitter's `main` branch, which we
  would not pin to.
- **Folding: content-manager enumeration,** with fold ranges from tree-sitter
  for code and from headings for markdown.

## Things the spike taught that the app must respect

- **`NSTextView(frame:textContainer: nil)` silently builds a TextKit 1 view.**
  Use `init(usingTextLayoutManager: true)`. Every TextKit 1 fallback also shows
  up as `textLayoutManager == nil`; the app should assert on it in debug
  builds. Touching `NSTextView.layoutManager` triggers the fallback.
- **Ctrl+←/→ belong to Mission Control** (switching Spaces) by default, and the
  system takes them before any app. The "Linux habits" layer in ADR 0003 can
  bind them, but Help must say they work only once the Mission Control
  shortcuts are changed in System Settings.
- **Tuist and grammar packages:** Tuist's generated resource-bundle target for
  tree-sitter-json kept the package's macOS 10.13 deployment target, which
  current Xcode refuses, and neither `baseSettings` nor `targetSettings`
  reached it. The spike uses Xcode's native package integration
  (`packages:` in `Project.swift`) instead. The main project should do the
  same for packages with resources, or check this before adopting Tuist's.
- **Synthesized key events do not exercise AppKit's text checking** the way a
  real keyboard does, so "typed quotes stay straight" is checked by hand.

## Hands-on check (before this ADR is accepted)

Open the spike app (`cd Spikes/EditorSpike && mise exec -- tuist generate`,
run the `EditorSpike` scheme) and, with a real keyboard:

1. Turn macOS's smart quotes and dashes **on** first (System Settings ▸
   Keyboard ▸ Text Input ▸ Edit; they were off on the machine the spike ran
   on, which would make this check pass for nothing). Then type `'`, `"`,
   `--`, `(c)` in the Markdown sample: all must stay as typed.
2. Home/End, ⌥←/→, ⇧-selection, Tab/Shift-Tab over several lines, ⌘Z.
3. ⌥⌘[ under "## Folding", then arrow and select across the fold.
4. Switch to the 1 MB JSON sample and type in the middle: no visible lag.
5. Insert image chip.

## Consequences

- We own caret, selection and key behaviour in our own subclass, which is the
  point, and also the maintenance cost.
- The spike code stays in `Spikes/EditorSpike/` as the evidence behind this
  ADR (ADR 0003 said it would be thrown away; keeping it is cheaper than
  re-deriving the results). It is not built by CI and not imported by the
  app; the app's editor is written fresh in milestone 2, with its logic in
  Core.
