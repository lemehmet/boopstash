# BoopStash

A scratch pad for macOS that remembers. Paste a snippet, an agent's output or a
screenshot, and find it again next week by what it was about, when you copied
it, or where it came from. An iOS companion syncs through your own iCloud.

> **Status: pre-alpha.** The plan is in
> [`docs/plan/milestones.md`](docs/plan/milestones.md) and the decisions behind
> it are in [`docs/adr/`](docs/adr/).

## Install

With [Homebrew](https://brew.sh):

```sh
brew install --cask lemehmet/boopstash/boopstash
```

Naming the cask in full trusts it for Homebrew's third-party tap check. The
app is signed with Developer ID and notarized by Apple, so it opens without a
Gatekeeper prompt. Or download the `.zip` from
[releases](https://github.com/lemehmet/boopstash/releases); each ships a
SHA-256 checksum:

```sh
shasum -a 256 -c BoopStash-0.1.1.zip.sha256
```

## What it is for

[Boop](https://github.com/IvanMathy/Boop) is a superb scratch pad: a buffer to
paste into, format and transform. BoopStash starts from the same idea and
changes three things:

- **Buffers persist.** Every note is kept, titled for you on-device, and
  searchable by title, content and age.
- **The editor stays out of the way.** No auto-closing quotes, no smart
  punctuation, Tab indents, and key bindings follow VS Code (or JetBrains, or
  Emacs) instead of AppKit's defaults.
- **Images are notes too.** Paste a screenshot; its text is recognised on-device
  and becomes searchable.

Boop's scripts keep working.

## Command line

The app carries a sandboxed `boopstash` command. The Homebrew cask puts
it on your `PATH`. Otherwise choose **BoopStash ▸ Install Command Line
Tool…** and pick a folder on your `PATH`, or link it yourself:
`ln -s /Applications/BoopStash.app/Contents/Helpers/boopstash /usr/local/bin/`.

```sh
kubectl get pods -o yaml | boopstash --title "pods before the upgrade"
boopstash < notes.txt              # the command reads only standard input
make 2>&1 | boopstash --label build-log  # makes the label if there is none
boopstash list --days 7
boopstash list --label bug -l "needs review"  # notes carrying both
boopstash search retry backoff --json
boopstash show 1a2b3c4d            # the ID list and search print
```

It works on the notes the app keeps, and the app shows what it adds at
once. Open BoopStash once first; it moves its notes where the command can
reach them. Like the app, the command has no network
access and can't read files you name; it only reads what is piped in.

## Privacy

- Your notes stay on your devices and in your own iCloud. There is no
  BoopStash server.
- iCloud sync, when it arrives, is optional. Every note and image is
  encrypted on your device before it is uploaded. With
  [Advanced Data Protection](https://support.apple.com/en-us/102651) turned on,
  that encryption is end to end: only your devices hold the keys, and Apple
  cannot read your notes. Without it, iCloud uses keys Apple can access, as it
  does for most iCloud data. If you sync, consider turning it on.
- No analytics, no crash reporting service, no update checks.
- Any AI is Apple's on-device model. Nothing is sent to a cloud model.
- The app never watches your clipboard. It reads it only when you paste or
  capture. If you want a clipboard history, macOS has one: turn on
  **System Settings → Spotlight → Clipboard**, then press ⌘Space, ⌘4.

[`SECURITY.md`](SECURITY.md) has the full list of what the app can and cannot
reach.

## Requirements

macOS 26 or newer. The iOS companion needs iOS 26. On-device titles need Apple
Silicon with Apple Intelligence turned on; without it, titles fall back to
simple rules.

## Building from source

Requires Xcode 26 or newer and [mise](https://mise.jdx.dev), which pins
[Tuist](https://tuist.dev):

```sh
mise install
mise exec -- tuist install
mise exec -- tuist generate
```

That opens `Boopstash.xcworkspace`. The generated project is never committed.
From the command line:

```sh
mise exec -- tuist test BoopstashCore   # unit tests
mise exec -- tuist build Boopstash      # the macOS app
```

## Acknowledgements

BoopStash is inspired by [Boop](https://github.com/IvanMathy/Boop) by Ivan
Mathy. It is a separate project, not affiliated with Boop.

## License

[Apache-2.0](LICENSE).
