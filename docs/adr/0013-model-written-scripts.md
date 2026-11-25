# ADR 0013 — Model-written scripts: the on-device model is not good enough yet

- **Status:** Accepted (2026-11-25)
- **Deciders:** boopstash maintainers
- **Refines:** ADR 0005 (formatting and transforms) and ADR 0007 (script
  service), within ADR 0001 (privacy baseline)
- **Evidence:** `Spikes/ModelScriptSpike/` (its own Swift package; not built
  by CI), results in `Spikes/ModelScriptSpike/RESULTS.md`

## Context

The planned script workbench (#247) has the user describe an edit in plain
language, has Apple's on-device model write a Boop-style script for it, and
runs that script in the script service (ADR 0007). The model never retypes
the user's text, so a small model cannot silently change a value, and the
result is deterministic. Whether the model writes usable JavaScript for
irregular input was unknown, and the model half of the workbench depends on
it (#246).

## What was measured

The spike sends an instruction and a sample of the text to
`SystemLanguageModel.default` in a new `LanguageModelSession`, takes the
script out of the reply, runs it on the **whole** input and compares the
output with the expected text. A run passes only when every line is right;
trailing spaces are not counted.

The script runs much as the script service runs it: a fresh `JSContext`
with Boop's `state`, in a child process that is sandboxed (no files, no
network) and killed after 2 seconds. Two differences. The spike has no
`require('@boop/…')`; the prompt says there is none, and a script that asks
for one is counted as a failure. And the child confines itself with
`sandbox_init` rather than carrying the service's App Sandbox, which a
plain executable cannot.

Three synthetic fixtures, the second in two forms:

| Fixture | Task |
|---|---|
| `urls` | 14 lines, each a number with stray text (two lines have none), to `https://tracker.example.test/issue/<number>` lines |
| `defines` | a register table pasted from a PDF (header, then NAME, bit and a description that starts on the same line or the next and wraps) to `#define REG_<NAME> (<bit>)` lines |
| `defines+comment` | the same, with the joined description as a `/* … */` comment |
| `string-table` | 12 lines of C error codes with values, comments and a blank line to a `static const char *const error_names[]` table |

Five variations, each one change from the baseline:

| Variation | Prompt wording | Sample | Reply |
|---|---|---|---|
| `baseline` | the script API spelled out, limits named, one example script | the first 4 to 7 lines | free text, one code block |
| `terse` | one sentence | as baseline | as baseline |
| `full-sample` | as baseline | the whole text | as baseline |
| `guided` | as baseline | as baseline | guided generation, a `@Generable` struct with one `script` string |
| `with-output` | as baseline, plus what the sample must become | as baseline | as baseline |

Ten runs per fixture and variation, 200 in all. A failed first try gets one
retry in the same session, with the script's error, or the first wrong line
and what it should have been, fed back. The full factorial (wording × sample
× reply × worked example, 16 cells per fixture) was cut to these five to
keep a run near twenty minutes; the runs per cell were not cut.

## Results

macOS 26.7.4 (25G422), Apple silicon, on 2026-11-25. FoundationModels has no
call that reports the model's version, so the OS build is the record of it.
Default sampling; replies capped at 1500 tokens. The seconds are the model's
alone, from the request to the complete reply.

| Fixture | Variation | First try | After one retry | Median s to first script | Slowest s |
|---|---|---|---|---|---|
| urls | baseline | 0/10 | 0/10 | 1.5 | 2.7 |
| urls | terse | 0/10 | 0/10 | 1.2 | 2.0 |
| urls | full-sample | 0/10 | 0/10 | 1.5 | 2.3 |
| urls | guided | 0/10 | 0/10 | 9.6 | 16.8 |
| urls | with-output | 1/10 | 1/10 | 1.7 | 2.1 |
| defines | baseline | 0/10 | 0/10 | 2.0 | 16.7 |
| defines | terse | 0/10 | 0/10 | 1.4 | 2.3 |
| defines | full-sample | 0/10 | 0/10 | 3.0 | 5.1 |
| defines | guided | 0/10 | 0/10 | 2.3 | 17.4 |
| defines | with-output | 0/10 | 0/10 | 2.6 | 4.7 |
| defines+comment | baseline | 0/10 | 0/10 | 4.0 | 6.3 |
| defines+comment | terse | 0/10 | 0/10 | 2.5 | 16.5 |
| defines+comment | full-sample | 0/10 | 0/10 | 3.4 | 5.8 |
| defines+comment | guided | 0/10 | 0/10 | 3.4 | 5.7 |
| defines+comment | with-output | 0/10 | 0/10 | 3.6 | 4.7 |
| string-table | baseline | 0/10 | 0/10 | 17.0 | 17.3 |
| string-table | terse | 0/10 | 0/10 | 9.8 | 17.2 |
| string-table | full-sample | 0/10 | 0/10 | 1.6 | 2.1 |
| string-table | guided | 0/10 | 0/10 | 1.0 | 3.0 |
| string-table | with-output | 0/10 | 0/10 | 1.2 | 1.9 |

| Fixture | First try | After one retry | Retries that fixed it |
|---|---|---|---|
| urls | 1/50 | 1/50 | 0/44 |
| defines | 0/50 | 0/50 | 0/49 |
| defines+comment | 0/50 | 0/50 | 0/50 |
| string-table | 0/50 | 0/50 | 0/50 |

Two earlier runs the same day, before the runner was sandboxed and the
seconds were narrowed to the model's own, agree: 0 of 160 first tries
without `with-output`, then 2 of 200 (3 after the retry), all on `urls`.
The model samples, so a rerun moves a cell by a run or two; it does not
move the picture.

Reproduce with, from the repository root (twenty to twenty-five minutes, on
a Mac with Apple Intelligence on):

```sh
swift run -c release --package-path Spikes/ModelScriptSpike ModelScriptSpike --out Spikes/ModelScriptSpike/RESULTS.md
```

### How failures look

The spike's own checks pass (each fixture's hand-written reference script
scores as a pass; a loop, a syntax error, a thrown error, a posted error and
a reply without a script are each reported as that; the runner's sandbox
refuses a file read and a connection), so the failures are the model's. `RESULTS.md` lists examples per fixture. In short:

- **Speed is not the problem.** A reply that is a script arrives in one to
  four seconds. The 17-second runs are replies that ran into the token
  cap, most of them `string-table` replies listing invented error names
  until cut off, which is why that fixture's baseline median is 17.
- **The script runs and writes the wrong text** (73 of 200 first tries). It
  keeps only lines that are a bare number, strips the stray text and
  forgets the prefix, hard-codes the sample's three registers, or returns
  the input unchanged. A frequent near miss assigns an array to
  `state.text` without joining it, which arrives as one comma-separated
  line.
- **The script fails** (78 of 200): JavaScript that does not parse, methods
  that do not exist (`"\n".join(list)`, from Python), `const` reassigned,
  or a `postError` on the first line that does not fit the shape the
  script assumed, most often a wrapped description line taken for a
  register.
- **No script at all** (42 of 200, all `string-table`): the model answers
  the task instead of writing a program for it. It replies with a
  JavaScript array of the names, or with statements and no `main`.
- **Guided generation is worse, not better.** The `script` string comes
  back with the JSON escapes resolved, so `split("\n")` holds a real line
  break and does not parse; six guided runs ended in `decodingFailure`
  after 17 seconds.
- **The retry does not help.** It fixed none of 193 failures. In 125 of
  them the model sent the same script back, character for character.
- **Nothing varied enough to matter.** Wording, the whole text as the
  sample, and showing the wanted output for the sample all stayed within
  one pass in ten of each other.

## Decision

- **The model path is not good enough to ship for any of the three
  fixtures on this OS.** Not for the easy one (`urls`, 1 of 50 after a
  retry), and not at all for the register table or the string table.

  | Fixture | Good enough to ship | Fallback |
  |---|---|---|
  | `urls` | No | The user writes the script in the workbench, starting from a line-by-line skeleton |
  | `defines`, `defines+comment` | No | The same; the row-and-wrapped-description loop is the part worth offering as a second skeleton |
  | `string-table` | No | The same line-by-line skeleton |

- **The workbench (#247) is built for hand-written scripts first:** the
  script editor, Run, the diff, Keep and Save as Script, with starting
  skeletons in place of a model's draft. It must be fully useful with no
  model. Generate is not part of it until the bar below is met.
- **The bar for adding Generate** is this spike, rerun on the OS in
  question: at least 8 of 10 first tries on `urls` and on `string-table`
  in the baseline variation, and at least 5 of 10 on `defines`. Rerun it
  when a macOS release changes the on-device model; the spike stays in the
  tree for that. A different model is out of scope here and would need its
  own ADR (ADR 0001).

These hold now, and for any later Generate:

- **Model-written code runs only in the script service** (ADR 0007): a
  sandboxed process with no entitlements, a fresh `JSContext` with Boop's
  API and nothing else, and the 2-second limit. It is never evaluated in
  the app, and the reply is treated as untrusted text until the user runs
  it.
- **Nothing is applied without review.** The result of a model-written
  script reaches the note only through the diff review from #245
  (`BoopTextView.review`, then `keepPendingReview` on Keep), which refuses
  over a note that changed meanwhile. There is no "generate and apply".
- **`SystemLanguageModel.default` only,** named explicitly, as
  `LiveModelTitler` does. Never `PrivateCloudComputeLanguageModel`, which
  sends the prompt to Apple's servers. The instruction and the sample stay
  on the device.
- **Free text, not guided generation,** for a script: ask for one code
  block and take it out of the reply.
- **When the model is unavailable** (Intel, Apple Intelligence off, model
  downloading), Generate is disabled and says why, from
  `SystemLanguageModel.default.availability`; everything else in the
  workbench works.
- **When the model fails,** the workbench says how, next to the script: no
  script in the reply, the script's error, the time limit, or the diff
  itself for a wrong result. A reply that holds code stays in the editor
  for the user to fix by hand. There is no automatic retry, which the
  numbers above do not justify; asking again is the user's choice.

## Things the spike taught

- A wrong script usually still runs and produces plausible text. Only the
  diff shows it, which is why review is not optional.
- Scoring on the sample alone would have flattered the model: scripts that
  hard-code the sample's rows pass there and fail on the whole text.
- An array assigned to `state.text` is turned into a comma-separated
  string by the JavaScriptCore bridge, in the spike and in the script
  service alike. A hand-written script can make the same slip; the
  workbench's diff will show it.
- The reply clean-up (`ScriptReply`: take the last fenced block that
  defines `main`, else bare code, else nothing) and the scoring (`Score`)
  are pure and tested in the spike's own package. They are **not** moved to
  `BoopstashCore`: with Generate deferred, nothing in the app would call
  them, and their shape should follow the workbench when it needs them.

## Consequences

- #247 is re-scoped before it leaves `proto`: no Generate, skeletons
  instead, the model named as a later addition gated on the bar above.
- The app gains no new use of the model, no entitlement and no network
  access from this ADR.
- The spike code stays in `Spikes/ModelScriptSpike/` as the evidence and as
  the test to rerun. It is not built by CI and not imported by the app.
