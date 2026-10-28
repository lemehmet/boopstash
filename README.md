# Boopstash

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
shasum -a 256 -c Boopstash-0.1.0.zip.sha256
```

## What it is for

[Boop](https://github.com/IvanMathy/Boop) is a superb scratch pad: a buffer to
paste into, format and transform. Boopstash starts from the same idea and
changes three things:

- **Buffers persist.** Every note is kept, titled for you on-device, and
  searchable by title, content and age.
- **The editor stays out of the way.** No auto-closing quotes, no smart
  punctuation, Tab indents, and key bindings follow VS Code (or JetBrains, or
  Emacs) instead of AppKit's defaults.
- **Images are notes too.** Paste a screenshot; its text is recognised on-device
  and becomes searchable.

Boop's scripts keep working.

## Privacy

- Your notes stay on your devices and in your own iCloud. There is no
  Boopstash server.
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

Boopstash is inspired by [Boop](https://github.com/IvanMathy/Boop) by Ivan
Mathy. It is a separate project, not affiliated with Boop.

## License

[Apache-2.0](LICENSE).
