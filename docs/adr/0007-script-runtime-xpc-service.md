# ADR 0007 — Scripts and JavaScript formatters run in an XPC service

- **Status:** Accepted (2026-10-28)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0005 (formatting and transforms)

## Context

ADR 0005 runs Boop-compatible scripts, Prettier and a SQL formatter in
JavaScriptCore with no network and no file access, and a time limit for each
run. JavaScriptCore's public API cannot enforce that limit. A `JSContext`
cannot be interrupted, and the only time-limit call
(`JSContextGroupSetExecutionTimeLimit`) is private API, which the Mac App
Store rejects (ADR 0004 keeps one code path for both channels). A script
stuck in a loop on a thread of the app would spin until the app quits.
Abandoning the thread does not stop it.

## Decision

- **A bundled XPC service, `BoopStashScripts.xpc`,** runs every script and
  every JavaScript formatter. The app sends it the script's source and its
  input as data and gets back the result, errors and info messages. Nothing
  else crosses the connection.
- **One fresh `JSContext` per run.** The context gets the Boop API and
  `require` for the bundled `@boop/` libraries, and nothing else. JavaScriptCore
  has no `fetch`, `XMLHttpRequest`, timers or file access unless they are
  injected, and none are.
- **A watchdog ends the service process** when a run passes its time limit
  (2 seconds). The app sees the connection interrupted, reports that the
  script was stopped, and the next run starts a new service process. This
  is the time limit ADR 0005 asks for, using only public API.
- **The service is sandboxed with no entitlements but the sandbox itself.**
  It has its own empty container: no network, no user files, and none of the
  app's data. A script cannot read the notes database even through a
  JavaScriptCore bug. The release check covers the service's entitlements as
  well as the app's.
- **The service's code is a thin adapter.** Header parsing, ranking, the
  script state (`text`, `selection`, `insert`) and applying the result to
  the note are pure logic in `BoopstashCore`, with tests.

## Consequences

- Scripts cost one process launch on first use, then reuse the running
  service. That is milliseconds, and nothing at all while no script runs.
- A crash in a script or in JavaScriptCore takes down the service, never
  the app or an unsaved note.
- Scripts that relied on state surviving between runs in Boop's long-lived
  per-script context start fresh each time. None of Boop's bundled scripts
  do.
