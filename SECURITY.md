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
  complete list of what the app may reach, and released builds add only
  iCloud for sync (`App/BoopstashCloud.entitlements`, ADR 0008). On the
  Mac the notes live in the container of an App Group,
  `A658882T2K.com.lemehmet.boopstash`, so the bundled command can reach
  them; only programs signed by the same team can open it (ADR 0009).
- **The `boopstash` command is sandboxed too.** It is in the app at
  `Contents/Helpers/boopstash`, and its entitlements are the sandbox and
  that App Group, nothing else (`App/CommandLine.entitlements`). It reads
  standard input and writes standard output. It opens no files, has no
  network access, and never talks to iCloud.
- **Scripts run in a separate, emptier sandbox.** Boop scripts and the
  JavaScript formatters run in a bundled XPC service whose only entitlement
  is the sandbox itself (`App/ScriptService.entitlements`, ADR 0007): no
  network, no files, none of your notes beyond the text a script is given. A
  script that runs too long is stopped by ending that process.
- **Files: only where you point it.** Beyond its own container and its App
  Group's container (where the Mac keeps the notes for the `boopstash`
  command, ADR 0009), the app can write only into a folder you choose in an
  open panel, which is how export works. It cannot read or write anything
  else on disk.
- **No network access except your iCloud.** There is no network-client
  entitlement. No analytics, no crash reporting service, no update checks. The
  only remote endpoint is the private database of the app's iCloud container,
  under your Apple Account, reached through the system's iCloud service. The
  app does not contact it, or check your account, until you turn on Sync with
  iCloud, which is off by default.
- **Problem reports are ordinary notes, sent to no one.** Help ▸ Report a
  Problem… makes an ordinary note, labelled `bug`, with the app's version and settings, counts
  and IDs describing what was on screen (never the text or title of a note),
  and, if you leave them ticked, a screenshot of the window drawn from the
  app's own views (no Screen Recording permission) and the last 10 minutes
  of BoopStash's own log. With Sync with iCloud on, the report and its
  screenshot sync to your private iCloud database like any other note, and
  nowhere else. Help ▸ Copy as GitHub Issue writes the selected
  note to the clipboard and asks the system to open
  `https://github.com/lemehmet/boopstash/issues/new` in your browser, with
  nothing in the URL. The app makes no request itself; what reaches GitHub
  is what you paste and submit there.
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
