# Security Policy

## Reporting a vulnerability

Please report security issues privately through GitHub's **"Report a
vulnerability"** (Security ▸ Advisories) on this repository. Do not open a public
issue for an undisclosed vulnerability. We aim to acknowledge within a few days
and will agree a fix and disclosure timeline with you.

## Security model

BoopStash keeps whatever its user chose to paste into it, which can include
credentials, internal URLs and other people's data. The posture is shaped
around that, and each point is enforceable rather than aspirational:

- **The app is sandboxed in every build.** Homebrew and App Store builds are the
  same code with the same entitlements. `App/Boopstash.entitlements` is the
  complete list of what the app may reach.
- **Files: only where you point it.** Beyond its own container, the app can
  write only into a folder you choose in an open panel, which is how export
  works. It cannot read or write anything else on disk.
- **No network access except your iCloud.** There is no network-client
  entitlement. No analytics, no crash reporting service, no update checks. Once
  sync ships, the only remote endpoint is the private database of the app's
  iCloud container, under your Apple Account.
- **The clipboard is read only when you ask.** No background polling. Paste,
  a menu item, a Services invocation, a drop or the capture hotkey are the only
  triggers.
- **Password-manager content is refused.** Pasteboard items marked as concealed
  or transient (`org.nspasteboard.ConcealedType`,
  `org.nspasteboard.TransientType`) are not stored.
- **AI runs on-device.** Apple's Foundation Models, NaturalLanguage and Vision
  frameworks only.
- **The markdown preview fetches nothing.** Remote images and resources are
  blocked by default.
- **Scripts run without network or file access.** Boop-compatible scripts run in
  a JavaScriptCore context that exposes nothing beyond the text being
  transformed, with a time limit per run.

Several of these describe features that have not shipped yet; they are the
constraints those features are built to. The decisions are recorded in
[`docs/adr/0001-platform-and-privacy-baseline.md`](docs/adr/0001-platform-and-privacy-baseline.md).

## Supported versions

Only the latest release receives fixes.
