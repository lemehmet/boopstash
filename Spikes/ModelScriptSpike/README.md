# ModelScriptSpike

The evidence behind [ADR 0013](../../docs/adr/0013-model-written-scripts.md):
can Apple's on-device model write a working Boop-style script from a
plain-language instruction and a short sample of the text?

It is a Swift package of its own, outside the app's Tuist project and not
built by CI. Measuring the on-device model needs a Mac with Apple
Intelligence on; measuring a model behind an endpoint (below), the
self-check and the tests do not.

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
  reported as that failure. For the script errors the message is checked
  as well as the kind (a `SyntaxError`, a `TypeError`, the posted text, a
  `ReferenceError` for `require`), so that a crash of the runner cannot
  pass for one. The runner's sandbox must refuse a file read and a
  connection. It runs before every measurement too.
- `swift test --package-path Spikes/ModelScriptSpike` tests the pure
  helpers (reply extraction, judging and scoring, the command line, the
  request and the reply of the endpoint mode, the request's time limit).
- A command line that is not understood is refused with the usage text
  and status 2, and nothing is measured: an option that is not one, an
  option given twice or without its value, a number that is not one.

The exit status is 0 after a measurement, 1 when the self-check fails or
the on-device model is unavailable, 2 for a refused command line, and 3
when the measurement finished but the script runner failed on some runs
(see "Runner errors" below).

## A model behind an endpoint

`--endpoint <base URL> --model <name>` measures a model served through an
OpenAI-compatible chat completions API (llama.cpp, llama-swap, Ollama, LM
Studio, vLLM, MLX servers) with the same fixtures, prompts, runner and
scoring, in place of the on-device model. It is how a model someone runs
themselves is held against ADR 0013's bar; the results so far are in
`RESULTS-endpoint.md`.

- The key, if the server wants one, is read from `MODEL_SPIKE_API_KEY`.
  Neither it nor the address is written to the report.
- `--temperature`, `--top-p` and `--max-tokens` set the request (defaults
  0.2, 1.0 and 2048).
- `--timeout` is the seconds one request may take in all, from sending it
  to the end of the reply (default 120). A server that keeps sending
  bytes is cut off at the limit too, and the attempt is reported as
  "request timed out". The report states the limit.
- `--extra-body '<JSON object>'` is merged into each request, for what
  the server at hand needs: switching a model's reasoning off is spelled
  differently by each. **The report records these fields as given, values
  and all**, so that a run can be repeated, and reports are committed:
  never put a key, a token or a password there. It may not set `model`,
  `messages` or `stream`; the run is refused if it does, as the report
  would then describe a request that was not the one sent.
- `--endpoint` without a value, and any of the options above without
  `--endpoint`, are refused (status 2) rather than measured on-device.
- Reasoning in the reply's content is dropped before the script is looked
  for: `<think>…</think>`, and also `…</think>` with no opening tag, which
  is what a server without a reasoning parser returns when the model's
  chat template puts the opening tag in the prompt. One case cannot be
  told: such a reply cut off at the token limit while still reasoning has
  no tag at all, and is judged as the text it is (as a rule, "no script
  in the reply") rather than as "cut off at the token limit". Give that
  server a reasoning parser, or switch the reasoning off.
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

## What the report counts

- **Runner errors.** When the child process cannot be started, or ends
  without a result (a trap inside the sandbox, say), nothing is known
  about the script. It is run again, up to three times in all. If the
  runner fails every time the attempt is a *runner error*, and the model
  is not sent a retry for it. On the first try, the run is in no figure
  of the report. On the retry, the run keeps its first try (a known
  failure) in the first-try figures and is left out of those after and
  about the retry, so the two columns of a row can have different
  denominators. The report lists these runs in a "Runner errors" section
  of its own, and the spike exits with status 3. Run those cells again
  before the report is used. A script that itself brings the runner down
  every time lands there too, and is not counted against the model: if a
  cell does so again on a new run, read its replies (`--dump`). A *script
  error* is only what the script itself raised or posted, and *timed out*
  only a script the watchdog had to kill.
- **"The same script again"** counts a retry when both replies hold a
  script and the two scripts are equal but for the space around them.
  Two replies without a script are not counted, however alike they are.

## Layout

- `Sources/SpikeKit/`: the tested code, with no model and no
  JavaScriptCore. The three fixtures (the register table in two forms),
  the prompts, `ScriptReply` (find the script in a reply), `Score`,
  `Judge` and `Outcome` (what an attempt amounts to, given the runner's
  answer), `SpikeArguments` (the command line), `ChatCompletion` (the
  endpoint's request and reply) and `Deadline` (the request's time limit).
- `Sources/ModelScriptSpike/`: the model adapters, the script runner and
  the report.
- `RESULTS.md`: the report of the run the ADR records.
- `RESULTS-endpoint.md`: the endpoint measurements.

Everything in the fixtures is made up: no real datasheet, tracker or code.
