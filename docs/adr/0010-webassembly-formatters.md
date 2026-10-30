# ADR 0010 — Formatters compiled to WebAssembly, in the script service, without JIT

- **Status:** Accepted (2026-10-29)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0005 (formatting), ADR 0007 (script service)

## Context

Format Document covers JSON and XML natively (ADR 0005), and Prettier's
languages and SQL in the script service (ADR 0007). Several languages that
BoopStash highlights had no formatter: Python, Go, shell, C, C++ and Java.
Their usual formatters are native programs. The wasm-fmt project publishes
them compiled to WebAssembly, under MIT wrappers.

ADR 0005 expected a Swift WebAssembly runtime. JavaScriptCore, which the
script service already uses, runs WebAssembly itself. When this ADR was
proposed (#158), it assumed the service would need
`com.apple.security.cs.allow-jit`, since a hardened process may not create
executable memory. That was measured before deciding. In a sandboxed,
hardened, Developer ID-signed process **without** the entitlement,
JavaScriptCore runs WebAssembly in its interpreter. A tight loop is about
15× slower, but real formatters stay well within an interactive budget:

| Formatter | Input | No JIT | JIT |
|---|---|---|---|
| gofmt | 1,200 lines of Go | 70 ms | 12 ms |
| shfmt | 600 lines of shell | 22 ms | 5 ms |
| Ruff | 840 lines of Python | 69 ms | 13 ms |

## Decision

- **No new entitlement.** The script service keeps only the sandbox. Each
  formatter runs in JavaScriptCore's WebAssembly interpreter, in the
  service, under its time limit, like Prettier.
- **Four formatters**, vendored unmodified in `Vendor/WasmFormatters`
  (about 4.4 MB) with the wrapper's licence and the formatter's own:
  - Ruff for Python (MIT): four-space indent per PEP 8, and the quote
    setting.
  - gofmt for Go (BSD-3-Clause): its one style.
  - shfmt for shell (BSD-3-Clause): the indent setting.
  - clang-format for C, C++ and Java (Apache-2.0 with the LLVM exception):
    LLVM style with the indent setting.
- **Not included:**
  - TOML, because Taplo's build is 35 MB.
  - Rust, Swift and Ruby, which have no WebAssembly formatter build.
- **Loading.** The packages are ES modules. When the service reads one, it
  drops the `export` keywords and gathers the exports, so the vendored
  files stay byte-identical to the published ones. The service's
  `WasmHost.js` supplies `TextEncoder` and `TextDecoder`, which
  JavaScriptCore lacks. Nothing is fetched: the module bytes come from the
  service's bundle.

## Consequences

- Python, Go, shell, C, C++ and Java gain Format Document, with error
  locations where the formatter reports them (gofmt and shfmt).
- If a future formatter is too slow interpreted, `allow-jit` would need a
  new ADR. That trade is now measured, not assumed.
- Updating a formatter means replacing its folder from the npm tarball
  named in `Vendor/WasmFormatters/VERSION`.
