# ModelScriptSpike

The evidence behind [ADR 0013](../../docs/adr/0013-model-written-scripts.md):
can Apple's on-device model write a working Boop-style script from a
plain-language instruction and a short sample of the text?

It is a Swift package of its own, outside the app's Tuist project and not
built by CI. It needs a Mac with Apple Intelligence on.

## Run

From the repository root:

```sh
swift run -c release --package-path Spikes/ModelScriptSpike ModelScriptSpike --out Spikes/ModelScriptSpike/RESULTS.md
```

That runs every fixture in every variation ten times (about twenty minutes),
prints the report and rewrites `RESULTS.md`, the table the ADR quotes. The
model samples, so the numbers move a little from run to run.

- `--runs N`, `--fixtures id,id`, `--variations id,id` narrow the run.
- `--dump <directory>` writes each prompt, reply and outcome to a file.
- `--selfcheck` checks the fixtures and the script runner without the
  model: each fixture's hand-written reference script must pass, and a
  looping script, a syntax error, a thrown error, a posted error, a
  `require`, a reply with no script and a wrong output must each be
  reported as that failure. It runs before every measurement too.
- `swift test --package-path Spikes/ModelScriptSpike` tests the pure
  helpers (reply extraction, scoring).

## What it does

For each run it starts a new `LanguageModelSession` on
`SystemLanguageModel.default` (never `PrivateCloudComputeLanguageModel`),
sends the instruction and the sample, takes the script out of the reply,
runs it on the fixture's whole input and compares the output with the
expected text. A failed first try gets one retry in the same session, with
the script's error or the first wrong line fed back.

The script runs as it does in the app's script service (ADR 0007): a fresh
`JSContext` with Boop's `state` object and nothing else, in a child process
that is killed after 2 seconds.

## Layout

- `Sources/SpikeKit/`: pure code. The three fixtures (the register table in
  two forms), the prompts, `ScriptReply` (find the script in a reply) and
  `Score`.
- `Sources/ModelScriptSpike/`: the model adapter, the script runner and the
  report.
- `RESULTS.md`: the report of the run the ADR records.

Everything in the fixtures is made up: no real datasheet, tracker or code.
