# Model-written scripts: a self-hosted model behind an endpoint

The same fixtures, prompt and scoring as `RESULTS.md`, against models served
by one self-hosted machine through an OpenAI-compatible API (`--endpoint`).
Measured on 2026-11-25 from macOS 26.7.4. The server's address is not
recorded; the model names are the public models' own.

Baseline variation only (the one ADR 0013's bar is stated in), ten runs per
fixture, a new conversation each run, temperature 0.2, top-p 1.0, replies
capped at 2,048 tokens. A run passes when the script's output on the whole
input equals the expected text.

| Fixture | Laguna S 2.1 (118B coder, as served) | Qwen3.6-35B, reasoning off | Qwen 3.8 Flash Next, reasoning off | On-device (`RESULTS.md`, all variations) |
|---|---|---|---|---|
| urls | 10/10 | 10/10 | 10/10 | 1/50 |
| defines | 10/10 | 8/10 | 10/10 | 0/50 |
| defines+comment | 10/10 | 9/10 | 10/10 | 0/50 |
| string-table | 10/10 | 6/10 | 10/10 | 0/50 |
| Median s to first reply, per fixture | 32.6, 8.5, 18.0, 7.5 | 2.6, 8.0, 13.9, 4.5 | 1.8, 5.9, 11.8, 4.5 | |
| Total for the 40 runs | 11.5 min | 5.7 min | 4.6 min | |

The first fixture's time for Laguna includes the server loading the model;
the others were loaded already or load faster.

Against ADR 0013's bar (8 of 10 first tries on `urls` and `string-table`, 5
of 10 on `defines`): Laguna and Qwen 3.8 Flash Next clear it on every
fixture; Qwen3.6-35B clears `urls` and `defines` and misses `string-table`.

## What the failures were

All seven of Qwen3.6-35B's failures were scripts that ran and wrote the
wrong text; the retry fixed none. On `string-table` the script skipped
lines (6 of 12 right), on `defines` it took a wrapped description line for
a register (4 of 10 right), and on `defines+comment` it ran a description
into the next row.

An earlier, interrupted run of Laguna had one wrong output on
`defines+comment` in 28 attempts, so 10 of 10 there is not a guarantee.

## Reasoning has to be off

Qwen 3.8 Flash Next reasons before it answers unless told not to. With
reasoning on:

- at a 2,048-token cap it passed `urls` (10 of 10, about 40 s each) and
  returned nothing on `defines` (0 of 12 before the run was stopped): each
  reply took about a minute and was empty, the whole allowance spent on
  reasoning;
- at an 8,192-token cap `defines` was still cut off at the limit, after
  about four minutes per attempt (0 of 3).

With `--extra-body '{"chat_template_kwargs":{"enable_thinking":false}}'`,
which is how a llama.cpp server is told to leave a Qwen model's reasoning
off, the same model is the table's right-hand column: 40 of 40 in under
five minutes, inside the 2,048-token cap.

The spike reports a reply that stopped at the token limit with nothing in
it as "cut off at the token limit", so it is not counted as a reply
without a script.

## Reproduce

```sh
MODEL_SPIKE_API_KEY=<key, if the server wants one> \
swift run -c release --package-path Spikes/ModelScriptSpike ModelScriptSpike \
  --endpoint <base URL> --model <model name> --variations baseline \
  [--extra-body '{"chat_template_kwargs":{"enable_thinking":false}}']
```
