# ADR 0009 — A bundled `boopstash` command, sharing the store through an App Group

- **Status:** Accepted (2026-10-29)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0001 (privacy baseline), ADR 0002 (storage), ADR 0004 (distribution)

## Context

M7 adds a command line (#156): `some-command | boopstash` keeps the
output as a note, and `boopstash search`, `list` and `show` read notes back
in a terminal. The Mac store lives in the app's sandbox container, which
no other process can open, and every BoopStash executable is sandboxed
(ADR 0001).

Options considered:

- **A bundled, sandboxed helper sharing an App Group** (chosen).
- **A URL scheme or AppleScript** that asks the running app to do the
  work. This needs the app running and gives no clean stdout for `search`
  and `show`.
- **An unsandboxed tool** reading the container directly. This breaks
  ADR 0001, and the App Store refuses it.

## Decision

- **The helper.** `boopstash` is a command-line executable in
  `BoopStash.app/Contents/Helpers/`, signed with the app and built from the
  same `BoopstashCore`. Its bundle identifier, `com.lemehmet.boopstash.cli`,
  is embedded in the binary's Info.plist section, which the sandbox needs.
  Its entitlements are `app-sandbox` and the App Group below, nothing
  else. It does not have `com.apple.security.inherit`, which is only for
  children the app itself launches: run from a shell, a tool with it is
  killed.
- **No files, no network.** The helper reads standard input and writes
  standard output. It cannot open paths given as arguments, and it does
  not try. `boopstash < notes.txt` works because the shell opens the file.
- **The App Group** is `A658882T2K.com.lemehmet.boopstash`, in the macOS
  team-prefixed form. Such a group needs no provisioning profile and no
  registration in the developer portal. macOS lets a process into the
  group's container when its signature carries that team. The app
  (`Boopstash.entitlements` and `BoopstashCloud.entitlements`) and the
  helper both claim it.
- **A profile must authorise it where there is one.** *Amended 2026-10-30
  (#179).* The claim needs no profile: the helper and ad hoc builds have
  none. But the release builds embed a profile for iCloud. In a process
  with a profile, a claim the profile does not authorise still launches,
  but clears the process's entitlements-validated flag, and iCloud could
  then refuse the app. So the release workflow and fastlane's
  `check_entitlements!` require the embedded profile to list `A658882T2K.*`
  (which Apple adds to Mac profiles once the App ID has App Groups) or the
  group itself. If that check fails, regenerate the profile.
- **The Mac store moves into the group,** once, by
  `NoteStore.sharedStoreFolder`, as the iOS store did for its share
  extension (#66). It is one rename, a store found in both places is
  merged, and the other folder is kept as a backup. The app uses the group
  only when it is signed by the team. A build signed ad hoc (Debug, CI)
  keeps its store at home, because macOS would refuse or prompt for the
  group container. The store opens `shared`: writers wait for each other.
  The helper never creates the store: until the app has moved it, the
  helper says to open BoopStash first. A store created by the helper would
  win a merge and leave the app's sync state (deletions not yet sent)
  behind. When the move is refused, the app says the command cannot reach
  the notes.
- **The app notices the helper's writes.** GRDB observation sees only its
  own process's commits. After each write the helper posts the Darwin
  notification `com.lemehmet.boopstash.changed`, which carries no data.
  The app re-reads its list on that notification and when it becomes
  active. The list refresh then starts the usual workers (image text,
  embeddings, titles), and sync sends the new notes.
- **Titles** are rule-based (`RuleTitler`), or `--title`, as in the share
  extension. The app asks for model titles for the command's notes when it
  refreshes after a write, and at launch.
- **Homebrew.** The cask links the helper onto `PATH` with `binary`. The
  App Store app carries the same helper, and its users can link it
  themselves; the README says how.
- **The app links it for other installs.** *Amended 2026-11-01 (#212).*
  GitHub, TestFlight and App Store installs left the command off `PATH`.
  BoopStash ▸ Install Command Line Tool… asks for a folder in an open panel
  (starting at `/opt/homebrew/bin`, `/usr/local/bin` or `~/.local/bin`) and
  links `boopstash` there to the running app's helper. The panel's grant
  comes from `files.user-selected.read-write`, which the app already has, so
  no entitlement is added and the entitlement checks are unchanged. It never
  overwrites anything but a broken link to a BoopStash helper, leaves a
  working link to one (the cask's) alone, refuses while the app runs
  translocated, and offers the `sudo ln -s` line for a folder it cannot
  write.

## Consequences

- A new entitlement, `com.apple.security.application-groups`. SECURITY.md,
  the release workflow's exact entitlement check and fastlane's
  `check_entitlements!` list it, and also check the helper's own
  entitlements.
- The store path on the Mac changes. Export, Settings and support
  documents that name the container now name the group container.
- A note captured from the shell with the app closed is synced when the
  app next runs. The helper never talks to iCloud.
