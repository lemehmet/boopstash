# ADR 0005 — Highlighting, formatting and transforms run in-process

- **Status:** Accepted (2026-10-28); where scripts and JavaScript formatters
  run is refined by ADR 0007 (a sandboxed XPC service, for the time limit)
- **Deciders:** boopstash maintainers

## Context

Boop formats JSON and runs JavaScript "scripts" that transform the buffer
(Base64, URL-encode, hashes, sorting…). BoopStash should format more than JSON
and keep Boop's scripts working. The sandbox (ADR 0004) rules out calling
formatters installed on the user's machine, and ADR 0001 rules out anything
remote.

These are three different features, kept apart:

- **Highlight**: colour the text by language.
- **Format**: rewrite the text into a canonical layout for its language.
- **Transform**: an arbitrary text-to-text function the user picks.

## Decision

- **Highlighting with tree-sitter grammars,** bundled. The same parse supplies
  fold ranges later (ADR 0003).
- **Formatting, in order of arrival:**
  1. Native: JSON (`JSONSerialization` / `JSONDecoder` with sorted-key and
     indent options), XML and property lists (`XMLDocument`,
     `PropertyListSerialization`).
  2. Prettier's standalone build running in JavaScriptCore: JavaScript,
     TypeScript, CSS/SCSS/Less, HTML, YAML, Markdown, GraphQL. A JavaScript SQL
     formatter alongside it.
  3. Later, formatters compiled to WebAssembly (for example ruff for Python)
     through a Swift WebAssembly runtime. Not committed to yet.
- **Transforms are Boop-compatible scripts** in JavaScriptCore, implementing
  Boop's script API (the `/** … **/` metadata header, `main(state)`, `state.text`,
  `state.selection`, `postError`, `postInfo`) so existing scripts run
  unchanged. Users can add their own scripts from a folder they choose.
- **Script contexts have no network and no file access.** JavaScriptCore
  exposes nothing but what we inject; no `fetch`, no timers beyond what a
  script needs, and a time limit per run.

## Consequences

- Bundled JavaScript (Prettier and the formatters) adds a few megabytes to the
  app and is updated through dependabot-tracked pins, not fetched at runtime.
- Boop's bundled scripts are MIT-licensed; if we ship any of them, their licence
  and attribution ship too (`THIRD_PARTY_NOTICES.md`).
- Formatter and script hosts are thin `Live*` adapters; script-API semantics
  (selection handling, metadata parsing) are pure and tested in Core.
