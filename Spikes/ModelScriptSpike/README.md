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

That runs every fixture in every variation ten times (twenty to twenty-five minutes),
prints the report and rewrites `RESULTS.md`, the table the ADR quotes. The
model samples, so the numbers move a little from run to run.

- `--runs N`, `--fixtures id,id`, `--variations id,id` narrow the run.
- `--dump <directory>` writes each prompt, reply and outcome to a file.
- `--selfcheck` checks the fixtures and the script runner without the
  model: each fixture's hand-written reference script must pass, and a
  looping script, a syntax error, a thrown error, a posted error, a
  `require`, a reply with no script and a wrong output must each be
  reported as that failure; the runner's sandbox must refuse a file read
  and a connection. It runs before every measurement too.
- `swift test --package-path Spikes/ModelScriptSpike` tests the pure
  helpers (reply extraction, scoring).

## A model behind an endpoint

`--endpoint <base URL> --model <name>` measures a model served through an
OpenAI-compatible chat completions API (llama.cpp, llama-swap, Ollama, LM
Studio, vLLM, MLX servers) with the same fixtures, prompts, runner and
scoring, in place of the on-device model. It is how a model someone runs
themselves is held against ADR 0013's bar; the results so far are in
`RESULTS-endpoint.md`.

- The key, if the server wants one, is read from `MODEL_SPIKE_API_KEY`.
  Neither it nor the address is written to the report.
- `--temperature`, `--top-p`, `--max-tokens` and `--timeout` set the
  request (defaults 0.2, 1.0, 2048 and 120 s).
- `--extra-body '<JSON object>'` is merged into each request, for what
  the server at hand needs: switching a model's reasoning off is spelled
  differently by each.
- The `guided` variation is FoundationModels' own and is left out.
- The script still runs in the spike's sandboxed child; only the spike
  itself talks to the endpoint.

## What it does

For each run it starts a new `LanguageModelSession` on
`SystemLanguageModel.default` (never `PrivateCloudComputeLanguageModel`),
sends the instruction and the sample, takes the script out of the reply,
runs it on the fixture's whole input and compares the output with the
expected text. A failed first try gets one retry in the same session, with
the script's error or the first wrong line fed back.

The script runs much as it does in the app's script service (ADR 0007): a
fresh `JSContext` with Boop's `state` object, in a child process that is
sandboxed and killed after 2 seconds. Two differences, both on purpose:

- There is no `require('@boop/…')`. The bundled libraries are the app's,
  and the prompt tells the model there is no `require`, so a script that
  asks for one fails here though the service would resolve it.
- The child confines itself with `sandbox_init` and the system's
  pure-computation profile (no files, no network), as a SwiftPM executable
  cannot carry the App Sandbox the service runs in. The self-check asks a
  child to read a file and open a connection, and fails unless both are
  refused.

The seconds in the report are the model's alone, from the request to the
complete reply; running the script is not counted.

## Layout

- `Sources/SpikeKit/`: pure code. The three fixtures (the register table in
  two forms), the prompts, `ScriptReply` (find the script in a reply) and
  `Score`.
- `Sources/ModelScriptSpike/`: the model adapter, the script runner and the
  report.
- `RESULTS.md`: the report of the run the ADR records.

Everything in the fixtures is made up: no real datasheet, tracker or code.
