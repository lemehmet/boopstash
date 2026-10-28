# ADR 0001 — Platform floor and privacy baseline

- **Status:** Accepted (2026-10-28)
- **Deciders:** boopstash maintainers

## Context

Boopstash is a scratch-buffer app in the spirit of
[Boop](https://github.com/IvanMathy/Boop): somewhere to drop a snippet, an
agent's output or a screenshot and find it again later. Unlike Boop it keeps
everything, which makes it a store of whatever its user happened to copy —
tokens, internal URLs, stack traces, customer data. The privacy posture is
therefore the product, not a feature of it.

Three facts shaped the baseline:

1. **Apple's on-device model needs the current OS.** The Foundation Models
   framework, which we want for titles and tagging, ships with macOS 26 and
   iOS 26 and needs Apple Silicon with Apple Intelligence enabled.
2. **macOS 26 already has a clipboard history.** Spotlight keeps one (off by
   default; retention 30 minutes, 8 hours or 7 days since 26.1). A second
   clipboard monitor would duplicate it and would have to poll the general
   pasteboard in the background.
3. **macOS is adding pasteboard privacy prompts.** `NSPasteboard.accessBehavior`
   lets the system alert when an app reads the general pasteboard without a
   paste-related user action. It is opt-in on macOS 26 today; we assume it will
   be enforced.

## Decision

- **Minimum deployment target: macOS 26, iOS 26.** No back-deployment and no
  feature gating by OS version. AI features are still gated on *availability*
  (Intel Macs, Apple Intelligence turned off), with a rule-based fallback.
- **No clipboard monitoring, ever.** The app reads the pasteboard only in
  response to a user action: ⌘V, a menu item, a Services invocation, a drop, or
  the "new note from clipboard" hotkey. Help points to Spotlight's clipboard
  history for anyone who wants one.
- **No network access except iCloud.** No analytics, no crash reporting
  service, no update checks, no font or script CDNs. The only remote endpoint
  is the user's own iCloud (CloudKit) container, and sync can be turned off.
- **AI is local only.** Foundation Models, NaturalLanguage and Vision, all
  on-device. No server-side model, no "private cloud" fallback. Concretely,
  code names `SystemLanguageModel` and never `PrivateCloudComputeLanguageModel`,
  which the macOS 27 SDK adds and which sends prompts to Apple's servers.
- **The markdown preview loads nothing remote.** Remote images and other
  resources are blocked by default, because fetching one tells its server the
  viewer's IP address and when the note was opened.
- **No location.** Recall is driven by the time, the source application
  (`NSWorkspace.frontmostApplication`, no Accessibility permission needed) and
  the detected content type. Reverse geocoding would send coordinates to Apple,
  and on a Mac the answer is nearly always "at the desk".
- **Concealed and transient pasteboard types are never stored.** Items marked
  `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType` (password
  managers) are refused even on an explicit capture, with a visible message.
  That includes an ordinary ⌘V into a note, since the note is saved: decided
  2026-10-28 (#21) over letting a deliberate paste through, so that no path
  stores a secret.

## Consequences

- Users on macOS 15 or earlier cannot run the app. Accepted: this is a new
  project and the floor buys a large API surface.
- "Prove it" must be checkable: the sandbox entitlements list exactly what the
  app can reach, and `SECURITY.md` says what it does not do. Any new entitlement
  or network call needs an ADR.
- Without a crash reporter, bug reports depend on users attaching logs and
  `.ips` files. The issue template asks for them.
