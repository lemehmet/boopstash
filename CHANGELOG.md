# Changelog

Notable changes, newest first. This project follows
[semantic versioning](https://semver.org); while the major version is 0,
breaking changes may land in a minor release.

## Unreleased

### New

- **Mac: a model you run yourself can draft scripts in the workbench
  (#269, ADR 0014).** Settings ▸ Model takes the base URL of an
  OpenAI-compatible endpoint (llama.cpp, llama-swap, Ollama, LM Studio,
  vLLM, MLX servers), an optional API key kept in the Keychain, and the
  model, picked from the service's own list or typed when the list cannot
  be fetched. It is empty by default, and while it is empty nothing
  changes and nothing is sent. With an endpoint set up the workbench has a
  prompt field and Generate: the draft goes into the editor and runs only
  when you run it. A mark beside Generate says what is sent and to which
  host, and is the stronger one when the host is not this Mac or the local
  network; What Is Sent shows the exact sample beforehand, which now grows
  to what fits the model's context, and lets you mark lines as examples,
  with what each should become. Generation settings (context length,
  reply limit, temperature, top-p, time limit, extra request fields) have
  defaults and a reset, and the help beside the extra fields lists how
  each kind of server switches reasoning off. A reply cut off at the token
  limit says so. The request is made by a separate sandboxed helper, the
  only part of BoopStash with a network entitlement; the app itself still
  has none. This changes the privacy baseline: see `SECURITY.md`.
- **Mac: the script workbench is a window of its own (#285).** It was a
  sheet on the note's window, bound to that window's place and size. Now
  it can be moved to any display, sized past the note's window, zoomed
  and made full screen, and its frame is remembered for the next time;
  so is the divider between the script and the diff, which can be
  dragged. It is still one note's: its title names the note, Keep applies
  to that note only, and it closes when the note's window closes or
  another note is opened in it (the script is kept for next time).
  Choosing Script Workbench… again brings the open one forward. The note
  stays usable while the workbench is open, so Keep over a note that was
  edited since the run applies nothing and says so; Refresh (⌘R) reads
  the selection, or the whole note, again and runs the script on it.
  What Is Sent is read from the note when the workbench learns where a
  request goes (shortly after it opens) and again only on Refresh or
  Check Again, so Generate still sends exactly what is
  on show. Escape no longer closes the workbench: it is a window, closed
  with ⌘W, its close button or Discard. Run Script with Preview keeps its
  sheet, and can be up at the same time; whichever of the two is kept
  second is refused, as its diff was made for the text before.
- **Mac: a script workbench (#247).** Scripts ▸ Script Workbench… (⌃⌘B)
  opens a workbench with a script on the left, highlighted as JavaScript, and
  on the right the diff of what it would change in the selection, or in
  the whole note when nothing is selected. Run (⌘↩) runs it in the script
  service and touches nothing; errors, what the script posted and the
  two-second limit are shown under the script. Edit and run again until
  the diff is right, then Keep (⇧⌘↩) applies it as one undo step, through
  the same check as the review: over a note that changed since the run it
  refuses, and Run makes the diff again. Discard leaves the
  note as it was, and the script is offered again the next time the
  workbench opens. Start From offers a blank script, a line-by-line
  skeleton, one for rows whose descriptions wrap over several lines, and
  any script in the library as a base to adapt. Save as Script writes the
  script with a Boop header into your Scripts folder, where the picker
  finds it; a name that one of your scripts or a bundled one already has
  is asked about first. There is no model in it (ADR 0013): the place
  where one that writes a first draft would plug in is there, and with
  none the workbench has no prompt field.
- **Mac: review a script's changes before keeping them (#245).** Scripts ▸
  Run Script with Preview… (⌥⌘B) runs the script you pick and shows what
  it would change as a diff: removed and added lines with a few lines of
  context, and the words that differ inside a changed line marked. Keep
  applies the result as one undo step; Discard, or Escape, leaves the note
  exactly as it was. With a selection, only the selection is diffed. A
  script that would change nothing shows no sheet and says so, and Keep
  refuses over a note that changed while the sheet was open. Clean Up
  Pasted Text can be previewed the same way from the picker. Run Script
  (⌘B) applies at once, as before.
- **Help in the app (#254).** Help ▸ BoopStash Help on the Mac, also in
  Settings, and Settings ▸ Help on iOS show the project's README, drawn
  by the note preview. It is the repository's own file, bundled at build
  time and never fetched: there is no web view, a picture it may gain is
  named and not loaded, and a link opens in the browser only when
  clicked. Links to the repository's files (`SECURITY.md`, `docs/adr/`)
  lead to them on GitHub. The system's Help item, which looked for a help
  book the app does not have, is gone.
- **What's New (#253).** On the first launch after an update, BoopStash
  shows once what changed since the version last run on that device: the
  notes of every version in between, newest first, with only the lines
  for that platform. A first install is shown nothing. The same notes
  are always in Help ▸ What's New and Settings on the Mac and in
  Settings ▸ What's New on iOS, and can be copied as Markdown or saved as
  a note. They are bundled with the app (`ReleaseNotes.json`), never
  fetched, and which version was seen is kept per device. The App Store's
  What's New text is now written from the same file, and a release or an
  App Store build stops when its version has no entry there.
- **Mac: Clean Up Pasted Text (#244).** Edit ▸ Clean Up Pasted Text, also
  in the script picker (⌘B), tidies text copied from a terminal or an
  agent's window: box-drawing and ASCII tables become Markdown tables, the
  indent every line shares and trailing spaces go, and so do ANSI colour
  and cursor codes. It works on the selection, or on the whole note when
  nothing is selected, as one undo step. A table inside a code fence is
  left as it is (the fence still loses the shared indent, trailing spaces
  and escape codes), and text with nothing to clean is left untouched.
- **Copy the text in an image (#243).** On the Mac, right-click an image
  in the editor (or select it and use the Edit menu) for Copy Text from
  Image, or Insert Text Below to put the text into the note under the
  image as one undo step. On iOS, touch and hold an image in a note's
  preview for Copy Text. An image whose text has not been read yet is
  read then, on device as always; one with no text says so and leaves
  the clipboard alone.
- **Text read from images keeps its rows.** What stands on one line in
  the picture is one line of text, and the cells of a table are a tab
  apart, so a screenshot of a table pastes into a spreadsheet as a
  table. This applies to images added from now on; text already read is
  kept as it is.

### Fixed

- **Mac: Clean Up Pasted Text on a selection keeps the code fence the
  selection starts in (#259).** A table selected inside a fence was
  converted, although cleaning the whole note leaves it alone, in two
  cases: when the fence's opening line stood behind a colour code, and
  when the selection began with an indented line of backticks or tildes
  that is code, which read as the fence's closing line once the
  selection's shared indent was removed.
- **Mac: Clean Up Pasted Text converts a table that has a line with a
  pipe straight above or below it (#258).** A line such as
  ``Output of `ls | wc`:`` right above a table drawn with `+---+` and
  `|`, or with box-drawing characters, read as one of its rows, and the
  table was left as it was. The table is now converted and the line
  stays as it is.
- **Mac: Clean Up Pasted Text no longer takes a code fence's opening
  line for a table row (#260).** An opening line with a pipe after the
  backticks or tildes, straight under a row and a rule, was rewritten as
  a row together with the code under it. It now ends the table above it
  and the fence is left as it is.
- **Mac: Copy Text from Image and Insert Text Below in the Edit menu
  follow the image's file (#251).** With an image selected, the two
  commands stayed off when iCloud brought the image afterwards, and stayed
  on when it was deleted on another device or its file went, until the
  selection or the focus changed. They now follow the image as it arrives
  and goes, and the image's chip in every open note is drawn again then:
  an image whose file is gone is shown as missing.
- **With iCloud sync on, a label, syntax setting or generated title
  changed and put back on another device is no longer taken for this
  device's own upload (#291, ADR 0015).** A note sent from here whose
  confirmation was lost, and which was edited here again, was recognised
  when it came back by its content and edit date. A change that keeps the
  edit date, made and undone elsewhere, left a note equal to the one sent,
  so it passed for it and the edit here was sent over it without a merge.
  Each note record now carries a random value naming that upload,
  encrypted like every other field, and only a record with a value this
  device made, and the content and date it was sent with, is its own;
  anything else is merged, with a "(conflict)" copy when the text
  differs. Devices on 0.4.5 or 0.4.6 keep syncing and leave the value
  alone; on a note a newer version has saved they can make a "(conflict)"
  copy where they would have recognised their own upload.
  The new field `Note.uploadID` was deployed to the CloudKit Production
  schema on 2026-11-26, which a release with this change needs (see
  `docs/plan/milestones.md`).
- **With iCloud sync on, a note a newer BoopStash has added a field to no
  longer gets a needless "(conflict)" copy.** A note sent from here whose
  confirmation was lost, and which was edited here again, is recognised
  as this device's own when it comes back. A field this version does not
  know, written by a newer version on another device and kept on the
  server, made it look like another device's edit, so the edit here was
  set aside as a copy. Only the fields this version writes are compared
  now; the other field stays on the server untouched (#233).
- **With iCloud sync on, another device putting a note back as it was is
  no longer overwritten without notice.** After an upload whose
  confirmation was lost, a note edited here again could be sent over
  another device's later save when that save had the same text as the
  upload (a change there, then a revert). Such a save is now merged like
  any other: its text wins and the edit made here is kept as a
  "(conflict)" copy (#232).
- **Mac: the workbench's script keeps its font and text colour after the
  editor was emptied.** A draft from Generate or a starting point from
  Start From that went into an editor with nothing in it (after deleting
  or cutting everything, or undoing back to nothing) came out in a
  proportional font with black text, unreadable in dark appearance. Text
  now takes the editor's monospaced font and the system's text colour
  however it gets there (#286).
- **Mac: a result is never applied over a note that changed only in how a
  character is encoded.** A script, Clean Up Pasted Text, Format, Replace
  All or a review's Keep that finished after an "é" in the note went from
  a letter plus a combining accent to the single letter (or back) took the
  note for unchanged and could ask for text past its end. Such a note now
  counts as changed, and the result is dropped with the usual message
  (#266).
- **Mac: the diff review shows a change of whitespace alone.** A line
  that went from a space to a tab, or from empty to a few spaces, was
  shown as a removed and an added row that looked the same. Whitespace
  that changed is now marked and drawn as glyphs under the mark ("·" for
  a space, "→" for a tab), also in a line of nothing else, and VoiceOver
  names it ("only 1 tab", "changed whitespace: 2 spaces") (#267).
- **Mac: letting go of the preview divider where you grabbed it no longer
  changes the split.** With the editor at its narrowest, such a drag
  stored the narrowest width over the size you had set, so a wider window
  later split differently (#226). A VoiceOver decrement at the narrowest
  width no longer does either.
- **Mac: Insert Text Below still inserts when the note is merged from
  iCloud while the image is being read.** The text was dropped with "The
  image is no longer in this note" although the image was still there. It
  now goes under the image in the merged note; when the note has the
  image more than once, before or after the merge, nothing is inserted
  and the message says so (#255).

## v0.4.6 — 2026-11-10

### Fixed

- **Mac: a closed window can be brought back from the menus.** Window ▸
  BoopStash (⌘0) shows the main window, opening one when the last was
  closed. File ▸ New Note and New Note from Clipboard open it too, so the
  new note is in view. Until now only the Dock icon brought it back, which
  App Review turned 0.4.4 down for.

## v0.4.5 — 2026-11-06

### New

- **Mac: find and replace in a note, as in VS Code (#235).** While editing, ⌘F
  opens a widget at the editor's top right with Match Case, Whole Word
  and Regular Expression toggles and the match count; ⌥⌘F unfolds the
  replace row. Enter and ⇧Enter step through the matches, Escape closes.
  Regular expression replacements take `$1`. The query is seeded from
  the selection or the word at the caret, and ⌘G steps to the next match
  without taking the keyboard from the note. With the note list focused,
  ⌘F still goes to the sidebar's Filter.

### Fixed

- **With iCloud sync on, a note could be emptied into a "(conflict)" copy.**
  Editing a note soon after it was first synced, for example pasting into
  a new note and running Format or a script, then moving to another note,
  could leave the note as it was first uploaded and put the edit in a
  conflict copy. The upload coming back from iCloud was taken for an edit
  made on another device (#215, #216). The same could happen when iCloud
  saved an upload but the reply never reached the device, for example on a
  dropped connection (#229).
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
