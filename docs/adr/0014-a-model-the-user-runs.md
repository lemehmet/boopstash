# ADR 0014 — A model the user runs themselves may write scripts

- **Status:** Accepted (2026-11-25); the app does not use it until #269 lands
- **Deciders:** boopstash maintainers
- **Amends:** ADR 0001 (privacy baseline) and ADR 0013 (model-written scripts)
- **Evidence:** `Spikes/ModelScriptSpike/RESULTS-endpoint.md` (added by #275)

## Context

ADR 0013 measured Apple's on-device model writing Boop-style scripts from a
plain-language instruction: one correct script in 200 tries, none on the
harder fixtures. The script workbench (#247) is therefore built for
hand-written scripts, and the model half of the idea had nowhere to come
from, because ADR 0001 allows no network access except iCloud and no model
that is not on the device.

People who care where their text goes often run a model of their own, on
their own machine or network. The same spike, pointed at such a server
through the OpenAI-compatible chat completions API, measured three models
on the baseline prompt, ten runs per fixture:

| Fixture | Laguna S 2.1 | Qwen3.6-35B, reasoning off | Qwen 3.8 Flash Next, reasoning off | On-device |
|---|---|---|---|---|
| urls | 10/10 | 10/10 | 10/10 | 1/50 |
| defines | 10/10 | 8/10 | 10/10 | 0/50 |
| defines+comment | 10/10 | 9/10 | 10/10 | 0/50 |
| string-table | 10/10 | 6/10 | 10/10 | 0/50 |

Two of the three clear ADR 0013's bar (8 of 10 on `urls` and
`string-table`, 5 of 10 on `defines`) on every fixture. A model that
reasons before it answers has to have its reasoning switched off: left on,
Qwen 3.8 Flash Next spent its whole reply allowance, at 2,048 tokens and
again at 8,192, and returned nothing on `defines`.

## Decision

BoopStash may send a request to **a language model endpoint the user
configures**, for one purpose: drafting a script in the script workbench.
This is the only exception this ADR makes to ADR 0001.

- **Off by default.** With no endpoint configured the feature does not
  exist in the interface, no helper is started and no request is made. The
  app chooses no service, ships no key and recommends no provider.
- **Any host the user types.** Where their text goes is the user's
  decision; nothing is refused for not being local. Because of that, the
  interface says plainly what is sent and where: a warning mark beside
  Generate and beside the endpoint in Settings, with the details on hover
  and as its accessibility label, and a stronger mark and wording when the
  host is not this Mac or the local network.
- **What is sent.** From the note, only what the workbench shows before
  Generate is pressed: the sample, and any lines the user marked as
  examples with what each should become. From the user, the instruction
  they typed. Nothing else of the note, no other note, no title, no search,
  no identifier of the user or the device.

  A request also carries what is not the user's text, and this is the
  whole list: BoopStash's own fixed prompt (how a script is written, the
  script API, an example script of ours); the model's name; the generation
  settings (context and reply limits, temperature, top-p); the extra
  request fields the user entered in Settings, as they entered them; and
  the user's API key, if they set one, as the `Authorization` header.
  Fetching the endpoint's model list sends the key and nothing else, and
  happens in Settings on the user's action.
- **The process that holds the notes still cannot reach the network.** The
  request is made by a separate, sandboxed helper process, which alone has
  the outgoing-network entitlement, the way the script service is kept
  apart in ADR 0007. For each request the app hands it exactly what the
  request carries, as listed above, and the endpoint's address; the helper
  keeps nothing between requests. The API key is read from the Keychain by
  the app and passed with the request: the helper has no
  `keychain-access-groups` and no `application-groups` entitlement, so it
  can reach neither the Keychain nor the App Group container the notes
  live in (ADR 0009). The app's own entitlements do not change. The
  release check enforces all of this, in both distribution channels.
- **The standard interface is the OpenAI-compatible chat completions API**
  (`<base>/v1/chat/completions`, and `<base>/v1/models` for the list),
  which llama.cpp, llama-swap, Ollama, LM Studio, vLLM and MLX servers
  speak. An optional key is kept in the Keychain and never logged.
- **The reply is untrusted text.** It goes into the workbench's editor. It
  runs only when the user runs it, in the script service (ADR 0007), and
  its result reaches the note only through the diff review (#245) when the
  user chooses Keep. There is no "generate and apply". These rules are ADR
  0013's and are unchanged.
- **Both distribution channels, one code path** (ADR 0004).
- **Reasoning off is the recommended setup,** with the context spent on
  the user's text and examples instead. Servers spell that switch
  differently, so the settings take extra request fields and offer the
  known spellings.

What ADR 0001 still forbids, unchanged: any other network access, analytics,
update checks, remote resources in the preview, a model service that
BoopStash picks, and `PrivateCloudComputeLanguageModel`. Titles, search and
image text stay on the device; this ADR gives them no use of the endpoint.

ADR 0013's "the workbench has no Generate" now reads: no Generate from the
on-device model until its bar is met, and Generate from a configured
endpoint under this ADR.

## Consequences

- "No network access except your iCloud" becomes "except your iCloud and a
  model endpoint you configure yourself". `SECURITY.md`, the README's
  privacy section, the privacy policy page and the App Store review notes
  change when #269 lands, not before: until then the old sentence is true.
- The entitlement list is still the promise: the app's file has no network
  key, and the one file that has it belongs to a helper that never sees the
  store.
- A user who points the endpoint at a hosted service sends their sample
  there. The interface tells them so; it does not stop them.
- macOS asks for Local Network access the first time a local endpoint is
  used, and plain HTTP is allowed for local addresses only.
- App Store review must be able to see that the feature is optional and
  that nothing goes to a server of ours.
- Review of changes: a network call anywhere but in the model helper, or a
  request that carries more than this ADR lists, is a defect of the highest
  severity, as any network call was before.
