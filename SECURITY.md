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
  open panel, which is how export works and how Install Command Line Tool…
  links the `boopstash` command into a folder on your `PATH`. It cannot read
  or write anything else on disk.
- **No network access except your iCloud and a model endpoint you configure
  yourself.** No analytics, no crash reporting service, no update checks. The
  app itself has no network-client entitlement. One remote endpoint is the
  private database of the app's iCloud container, under your Apple Account,
  reached through the system's iCloud service. The app does not contact it, or
  check your account, until you turn on Sync with iCloud, which is off by
  default. The other is described next, and is off by default too.
- **A model you run yourself, if you set one up (ADR 0014).** Settings ▸
  Model takes the address of an OpenAI-compatible model endpoint, on your Mac,
  on your network or wherever you say. It is empty by default; while it is
  empty the feature does not exist, no helper process is started and no
  request is made. BoopStash picks no service, ships no key and recommends no
  provider.
  - *When a request is made.* Only when you press Generate in the script
    workbench, or enter the address or press Refresh or Test in Settings, and
    only to the address you typed. Nothing at launch, in the background or on
    a timer. A redirect to another host is not followed.
  - *What a request carries.* Your instruction, the sample of the note the
    workbench shows under What Is Sent before you press Generate, and any
    lines you marked as examples; BoopStash's own fixed prompt; the model's
    name; the generation settings; the extra request fields you entered; and
    your API key, if you set one, as the `Authorization` header. Nothing else
    of the note, no other note, no title, and nothing that identifies you or
    your Mac: the other headers are fixed (`User-Agent: BoopStash`, without a
    version) and there are no cookies. Refresh sends the key and nothing
    else. Test sends an instruction and a two-line sample of BoopStash's own,
    none of your text.
  - *Which process makes it.* A separate sandboxed helper
    (`Contents/XPCServices/BoopStashModel.xpc`), whose entitlements are the
    sandbox and the outgoing-network key and nothing else
    (`App/ModelService.entitlements`). It has no App Group, so the container
    your notes live in is closed to it, and it calls no Keychain API. The app,
    which holds the notes, still cannot reach the network. The release check
    refuses a build in which the app has a network entitlement or the helper
    has any other.
  - *The key.* The app keeps it in the Keychain, for the endpoint it was
    entered for, and passes it with each request. It is never written to a
    note, a log, the settings file or a problem report.
  - *Where it goes is your decision.* Any host you type is allowed. A warning
    mark beside Generate and beside the address in Settings says what is sent
    and to which host; when the host is not your Mac or your local network,
    the mark is the stronger one and says the text leaves your local network.
    Plain `http://` is accepted for local addresses only.
  - *The reply is untrusted text.* It goes into the workbench's editor and
    runs only when you run it, in the script sandbox above; nothing reaches
    the note without the diff review.
- **Problem reports are ordinary notes, sent to no one.** Help ▸ Report a
  Problem… makes an ordinary note, labelled `bug`, with the app's version and settings, counts
  and IDs describing what was on screen (never the text or title of a note),
  and, if you leave them ticked, a screenshot of the window drawn from the
  app's own views (no Screen Recording permission), which shows whatever the
  window shows, the open note's text included, and the last 10 minutes
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
- **AI runs on-device, except a model you point it at.** Titles, search by
  meaning and text in images use Apple's Foundation Models, NaturalLanguage
  and Vision frameworks and a bundled model, on the device only. The one
  exception is the script workbench's Generate, with the endpoint you
  configured, as above.
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
