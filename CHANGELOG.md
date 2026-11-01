# Changelog

Notable changes, newest first. This project follows
[semantic versioning](https://semver.org); while the major version is 0,
breaking changes may land in a minor release.

## Unreleased

### Fixed

- **With iCloud sync on, a note could be emptied into a "(conflict)" copy.**
  Editing a note soon after it was first synced, for example pasting into
  a new note and running Format or a script, then moving to another note,
  could leave the note as it was first uploaded and put the edit in a
  conflict copy. The upload coming back from iCloud was taken for an edit
  made on another device (#215, #216).
- **The note list could stay on an old filter.** Changing the filter
  twice in quick succession, as New Note does when it clears a label
  filter, could leave the list showing the first filter's notes until the
  next edit, on the Mac, iPhone and iPad. The label list had the same
  race (#200).

## v0.4.4 — 2026-11-01

### New

- **Mac: install the `boopstash` command from the app.** BoopStash ▸
  Install Command Line Tool…, or Settings ▸ General, links it into a folder
  on your `PATH`, for installs from the GitHub download, TestFlight or the
  App Store; the Homebrew cask already does (#212).

## v0.4.3 — 2026-10-31

### Fixed

- **Mac: the preview beside the editor keeps its size.** Dragging the
  divider now lasts through switching notes, hiding and showing the
  preview, and relaunching; it starts at half each (#207).
- **iPhone: notes after the first stayed blank with the preview on.** The
  first note opened rendered; every later one showed only its title (#206).

## v0.4.2 — 2026-10-31

### New

- **Labels on the Mac.** Put coloured labels on notes, as on GitHub
  issues: Note ▸ Labels… (⌃⌘L) or the tag button in the toolbar lists them,
  filters as you type and creates a label you name. Labels show as chips in
  the note list; click one, or check labels in the Filter menu, to list only
  the notes carrying all of them. Settings ▸ Labels creates, renames,
  recolours and deletes them.
- **Labels everywhere else.** On iPhone and iPad, notes show their labels
  as chips, and the Filter menu lists only the notes carrying every checked
  label; labels are made and assigned on the Mac. Exported files list a
  note's labels in their front matter. The `boopstash` command takes
  `--label NAME` (or `-l`) to list or search only notes carrying every
  named label, or to label a captured note, making the label if there is
  none; `--json` output includes each note's labels.
- **Report a Problem** on the Mac. Help ▸ Report a Problem… makes a note
  labelled `bug` describing the app and what is on screen: versions, sync
  state and the open note's settings, but not the note's text. A screenshot
  of the window, which shows whatever is open, and recent log lines are
  included unless you leave them out. You add what happened, and
  Help ▸ Copy as GitHub Issue copies it for an issue. The report is an
  ordinary note: it syncs if sync is on, and nothing is sent anywhere else.

### Fixed

- **The folding arrows were dots.** They are chevrons now, sized from the
  editor's font, with a gutter that grows to match.

- **Clearing a note's setting syncs.** Setting a note's highlighting back to
  automatic on one device left the old language on the others.

## v0.4.1 — 2026-10-30

### Fixed

- **The Mac editor showed no text.** The folding gutter painted over the
  note beside it, so the editor looked empty; the text was there all along.

## v0.4.0 — 2026-10-30

### New

- **Search by meaning.** A search also lists notes that say the same thing
  in other words, under "Similar in meaning": "invoice" finds "bill for
  March". Show Similar Notes on a note lists the notes closest to it. A
  small language model bundled with BoopStash reads each note on your
  device. Nothing leaves it, and the index is never synced. On the Mac,
  Settings ▸ General ▸ Search ▸ Find notes by meaning turns it off.
- **Folding** on the Mac. Blocks of code, JSON, XML and HTML elements,
  Markdown sections and indented text fold from an arrow beside their
  first line, or with Edit ▸ Folding (⌥⌘[ and ⌥⌘] in VS Code's bindings,
  ⌘- and ⌘= in JetBrains'). Folding only hides lines: the note's text,
  search, copy and export are unchanged.
- **A `boopstash` command** on the Mac. `some-command | boopstash` keeps
  the output as a note, and `boopstash list`, `search` and `show` read
  notes in a terminal, with `--json`. The Homebrew cask puts it on your
  PATH. It is sandboxed like the app: it reads only what is piped to it.
- **Format Document for Python, Go, shell, C, C++ and Java**, with Ruff,
  gofmt, shfmt and clang-format, run in BoopStash's sandboxed script
  process.
- **The language in use** shows in the language menu, marked when it was
  detected rather than chosen.
- **Toolbar buttons** for Paste as Markdown, Run Script, Show Preview and
  Preview Beside the Editor.

### Changed

- The preview renders Markdown notes only. Other notes show a placeholder,
  with a button to treat the note as Markdown.
- On the Mac, notes move into a folder shared with the `boopstash`
  command (an App Group container) on first launch. Your scripts and
  `keybindings.json` stay where they were.

### Fixed

- XML formatting keeps text, CDATA and processing instructions exactly,
  and leaves documents using `xml:space="preserve"` alone.
- Image chips are built for the visible part of a note only, with small
  thumbnails decoded off the main thread, so long notes with many images
  scroll smoothly.
- Formatting a large document can be cancelled at any point, and uses the
  indent width setting everywhere.

### Privacy

- No new network access. The language model, the formatters and the
  command all run on your device, inside the sandbox. The script process
  still has only the sandbox: WebAssembly runs without JIT (ADR 0010).
- The App Group is the only new entitlement (ADR 0009).

## v0.3.0 — 2026-10-29

### New

- **iCloud sync.** Settings ▸ General ▸ iCloud ▸ Sync with iCloud keeps your
  notes and images the same on every Mac, iPhone and iPad signed in to your
  Apple Account. It is off until you turn it on; until then BoopStash does
  not contact iCloud at all, not even to check your account. Every field of
  every note is encrypted on your device before it is uploaded; with
  Advanced Data Protection that encryption is end to end. A note changed on
  two devices at once keeps both versions: the other device's text, and
  yours as a conflict copy. Sync Now and the last sync time are in Settings.
- **BoopStash for iPhone and iPad.** The same notes, search and age filter,
  syntax highlighting and light editing (plain text, no smart punctuation),
  the Markdown preview, New Note from Clipboard, and text recognised in
  images, all on the device.
- **Share to BoopStash** on iPhone and iPad: share text, a link or up to ten
  images from any app and they become a note. Anything it cannot keep (an
  image over 20 MB, say) is named rather than dropped silently.
- **On the Mac App Store** as well as Homebrew, as one free app for Mac,
  iPhone and iPad.

### Fixed

- A note was not titled by Apple Intelligence when its text had only
  reference-style images, and images referenced that way, or from inside
  a quote, could be removed by the clean-up of unused images.
- Detecting what kind of text was pasted no longer reads all of a very
  large paste.

### Privacy

- The only network access is your own iCloud, and only with sync on. The
  app has no network entitlement: iCloud is reached through the system
  (ADR 0008).
- The App Store listing says Data Not Collected, and the iOS app's privacy
  manifest records the same.

## v0.2.0 — 2026-10-29

### New

- **Images.** Paste an image into a note (⌘V with an image on the
  clipboard), drop one on the editor or the note list, or capture an
  image-only clipboard with New Note from Clipboard, ⌃⌥⌘V or Services.
  Images are kept with the note, up to 20 MB each. In the editor each one
  shows as a chip with a thumbnail: one Backspace removes it, the caret
  steps over it, copying it copies its markdown, and a double-click opens
  it in Quick Look. Export writes images beside the notes and links them.
- **Text in images is searchable.** BoopStash reads the text of each image
  with Apple's on-device text recognition, so a word in a screenshot finds
  its note; such a match is marked "in image" in the list. Nothing leaves
  the Mac.
- **Markdown preview.** View ▸ Show Preview (⌥⌘P) shows the note rendered,
  beside the editor or in its place: headings, emphasis, lists and task
  lists, quotes, tables, highlighted code and the note's images. It is drawn
  natively and never loads anything: remote images are named, not
  fetched, and HTML in a note is shown as text.
- **Format Document** (Edit menu; ⇧⌥F with VS Code keys, ⌥⌘L with
  JetBrains keys) formats the note, or the selection, by its language:
  JSON and XML natively (JSON keeps every number, escape and key order;
  Format JSON, Sorting Keys orders keys), JavaScript, TypeScript, CSS,
  HTML, YAML and Markdown with Prettier, and SQL with sql-formatter.
  Settings ▸ Editor ▸ Formatting has the indent width, quote style, SQL
  dialect and keyword case. Text that cannot be parsed is left as it is,
  with the line and column of the problem.
- **Boop scripts.** Scripts ▸ Run Script… (⌘B) runs Boop's 71 scripts on
  the selection, each part of a multiple selection, or the whole note:
  Base64, URL and HTML encoding, hashes, case changes, sorting, JSON and
  YAML conversion and more. Run Last Script is ⇧⌘B. Your own Boop scripts go
  in the Scripts folder (Settings ▸ General ▸ Show Scripts Folder); one
  named like a built-in replaces it.

### Privacy

- Scripts and the JavaScript formatters run in a separate sandboxed
  process with no network, no files and none of your notes beyond the text
  they are given; one that runs too long is stopped (ADR 0007).
- Text recognition and the preview add no network access; the app still
  has no network entitlement.

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
