# ADR 0014 — A model the user runs themselves may write scripts

- **Status:** Accepted (2026-11-25); implemented by #269, which amended it (see the end)
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
  keeps nothing between requests.

  The API key is the app's to keep. The app stores it in the
  data-protection keychain under its own access group, reads it, and
  passes it with each request. The helper is a different program with a
  different application identifier and shares no keychain access group
  with the app, which is what keeps that item out of its reach; no missing
  entitlement does that by itself, since any sandboxed process may use a
  keychain of its own. So the rule is on what the helper does: it calls no
  Keychain API at all, and it has no `application-groups` entitlement, so
  the App Group container the notes live in (ADR 0009) is closed to it.
  The app's own entitlements do not change. The release check covers the
  helper's entitlements in both distribution channels, and review covers
  the rest: a `SecItem` call in the helper is a defect.
- **Every request is the user's.** A request goes out only as the result
  of the user pressing Generate, or entering an endpoint or pressing
  Refresh or Test in Settings, and only to the endpoint they configured.
  No request is made at launch, in the background, on a timer, to a host
  the user did not type, or while no endpoint is configured.
- **The standard interface is the OpenAI-compatible chat completions API**
  (`<base>/v1/chat/completions`, and `<base>/v1/models` for the list),
  which llama.cpp, llama-swap, Ollama, LM Studio, vLLM and MLX servers
  speak. An optional key is kept in the Keychain and never logged.
- **The reply is untrusted text.** It goes into the workbench's editor. It
  runs only when the user runs it, in the script service (ADR 0007), and
  its result reaches the note only through the diff review (#245) when the
  user chooses Keep. There is no "generate and apply". These rules are ADR
  0013's and are unchanged.
- **Both distribution channels, one code path** (ADR 0004): Homebrew and
  the Mac App Store.
- **macOS only.** The safeguard this decision rests on is that the app
  holding the notes has no network entitlement and a separate sandboxed
  helper makes the request. Neither exists on iOS: an iOS app needs no
  entitlement to reach the network and has no XPC helper. The iOS app gets
  no model endpoint, no Settings for one and no request path, and none of
  this is compiled into it; bringing it to iOS would need its own ADR.
- **Reasoning off is the recommended setup,** with the context spent on
  the user's text and examples instead. Servers spell that switch
  differently, so the settings take extra request fields and offer the
  known spellings.

What ADR 0001 still forbids, unchanged: any other network access, analytics,
update checks, remote resources in the preview, a model service that
BoopStash picks, and `PrivateCloudComputeLanguageModel`. Titles, search and
image text stay on the device; this ADR gives them no use of the endpoint.

**What this does to ADR 0013.** ADR 0013 says "Generate is not part of
[the workbench] until the bar below is met" and "A different model is out
of scope here and would need its own ADR". This is that ADR. The bar still
governs the on-device model. Of the rules ADR 0013 lists as holding "now,
and for any later Generate", for Generate from a configured endpoint:

- *Model-written code runs only in the script service* — applies as
  written.
- *Nothing is applied without review* — applies as written.
- *`SystemLanguageModel.default` only … The instruction and the sample
  stay on the device* — replaced. It remains the rule for any on-device
  generation. For an endpoint, what leaves the device and to where is what
  this ADR lists, and nothing more.
- *Free text, not guided generation* — applies as written.
- *When the model is unavailable … from
  `SystemLanguageModel.default.availability`* — replaced. With no endpoint
  configured there is no Generate at all. With one configured that cannot
  be used (unreachable, refused, no model chosen), Generate is disabled
  and says why; everything else in the workbench works.
- *When the model fails … no automatic retry* — applies as written, with
  one more failure named: a reply cut off at the token limit before any
  answer.

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

## Amended while building it (#269)

Building the feature settled points the decision left open, and narrowed
two. None widens what may be sent.

- **What Test sends.** Test in Settings makes the same request as
  Generate, with an instruction and a two-line sample of BoopStash's own
  in place of the user's: it shows that the endpoint, the model, the key
  and the extra request fields work together, and sends none of the
  user's text.
- **The model list is remembered.** The names last fetched are kept with
  the settings, so opening Settings shows them without a request. The list
  is fetched when the user enters the base URL or presses Refresh, and not
  when Settings merely opens or when the key changes.
- **The rest of the HTTP request is fixed.** Beside `Authorization` the
  helper sends `Accept`, `Content-Type`, `Accept-Language: en` and
  `User-Agent: BoopStash`, without a version, set by us so that the
  system's defaults (which name the OS and the user's languages) are not
  sent. It keeps no cookies, no cache and no stored credentials, and
  follows no redirect: a redirect would carry the text and the key to a
  host the user did not type, so it is reported instead.
- **Plain HTTP is refused for a host that is not local, by our own rule.**
  App Transport Security's local-networking allowance also lets plain HTTP
  through to any numeric address, so the app and the helper both check:
  `http://` is accepted for this Mac and the local network (loopback,
  private and link-local addresses, `.local` and bare host names) and
  refused otherwise, as is a base URL holding a user name, a password, a
  query or a fragment. "Any host the user types" stands, over HTTPS.
- **The key belongs to an endpoint.** It is stored under the scheme, host
  and port it was entered for, so changing the base URL to another host
  does not send the first host's key there.
- **The extra request fields cannot change what the interface says is
  sent.** They are merged in as entered, except that an object naming
  `messages`, `model`, `stream`, `temperature`, `top_p` or `max_tokens` is
  refused, with the reason shown in Settings: the conversation is what the
  workbench showed, the model is the one chosen, the reply is read whole,
  and the three generation settings have fields of their own, from which
  the sample's size is worked out. So no merged value differs from the
  one shown.
- **What is shown is what is sent, and where.** The workbench takes the
  sample from the note when it shows it, and Generate sends that sample
  and those examples: the note is not read again, so text that changed
  under the open sheet is not sent unseen. The request also names the
  destination the sheet showed; if the settings no longer give that
  destination, nothing is sent until the sheet has shown the new one. The
  key is read for the address the request goes to.
- **The time limit is for the whole request,** from its start to the end
  of the reply, not for the gap between two pieces of it, and its expiry
  is reported as a timeout.
- **Reasoning is dropped from the reply** in both spellings servers use:
  between `<think>` tags, and before a closing tag alone, which is what
  arrives when the chat template put the opening tag in the prompt.
- **Nothing of the endpoint is in a problem report or a log.** Report a
  Problem collects a fixed list of facts that the endpoint is not on: not
  its address, model, key or extra request fields. Neither the app nor
  the helper logs a request, a reply or a setting of this feature.
- **A build without an application identifier cannot keep a key.** The
  data-protection keychain needs one; an ad hoc Debug build has none, is
  refused by the Keychain, and says so. The key is not kept anywhere else
  instead. Released builds in both channels are provisioned.
