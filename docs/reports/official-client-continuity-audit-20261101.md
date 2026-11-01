# Official client and provider continuity audit — 2026-11-01

Eight client/provider contract defects were repaired and a Codex fixture guard was
strengthened in eight draft PRs in Native Stack #47014,
whose top layer is [PR #47030](https://github.com/jeong-sik/masc/pull/47030). The review followed current
source, installed client help/schema, primary documentation and read-only runtime
evidence. It does not establish that every provider is free of bugs or that the
repairs are installed.

| Draft PR | Defect | Continuity boundary repaired |
| --- | --- | --- |
| [#47008](https://github.com/jeong-sik/masc/pull/47008) | Muse discarded typed quota/reset facts and misclassified account rest in Board/exact lanes | MSP decode → account-scoped observation → Keeper/Fusion/readiness/Board/exact failure consumers |
| [#47008](https://github.com/jeong-sik/masc/pull/47008) | A Muse event gap could hide compaction; a gap before turn acknowledgement could also turn a lost response into quiet completion | Event observation → held Memory invalidation → durable settlement → resumed prompt; missing final response remains uncertain |
| [#47013](https://github.com/jeong-sik/masc/pull/47013) | GLM cleared the current tool exchange's reasoning together with past user turns | Source-stamped reasoning → checkpoint codec → semantic user boundary → next HTTP request |
| [#47019](https://github.com/jeong-sik/masc/pull/47019) | Visible-text cleanup corrupted or removed a native inline carrier while keeping its exact replay witness | Provider parser → Keeper finalization → disk checkpoint → restored original request bytes |
| [#47022](https://github.com/jeong-sik/masc/pull/47022) | Scoped Kimi Coding declarations did not inherit the native Kimi replay contract; the alias also omitted streamed reasoning | Shipped runtime binding → scoped capabilities → sync/SSE parsing → source identity → disk checkpoint → tool continuation/new user request |
| [#47024](https://github.com/jeong-sik/masc/pull/47024) | Kimi Coding rejected documented low/high/max effort requests | Shipped binding → typed default-on contract → admission → serialized effort; omitted defaults remain omitted |
| [#47025](https://github.com/jeong-sik/masc/pull/47025) | GLM preservation with an omitted default-enabled thinking toggle lost history and omitted its requested wire field | Provider parser → stable provenance → disk checkpoint → effective default and explicit controls → next user request |
| [#47026](https://github.com/jeong-sik/masc/pull/47026) | Antigravity rejected five documented non-completed states as unknown protocol strings | Exact status/init identity → ambiguous durable recovery; no successful turn ACK or candidate replay of uncertain native effects |
| [#47030](https://github.com/jeong-sik/masc/pull/47030) | Codex fixture assertions could be logged and swallowed by production stream-observer isolation | Snapshot the first delta once, assert after cleanup and rethrow ordinary observer failures; preserve cancellation/interruption and final serial-order assertions |

The Kimi change deliberately uses the three shipped model bindings. It does not
guess capabilities for arbitrary operator-created model IDs. Its six fixture
cases retain synthetic reasoning carriers through production code; they do not
certify a provider-reported model identity or live account access.

Kimi effort admission is a separate repair from replay. Explicit disable emits
`none`; the provider documents routing this control to non-thinking K2.8 Preview.
The repair does not certify that disabling thinking preserves K3 model identity.

## Continuity paths inspected

```mermaid
flowchart TD
  M[Selected Memory and durable tool results] --> P[Typed model input projection]
  P --> N[Native official client: session and turn]
  P --> A[HTTP API: stamped reasoning and tool messages]
  N --> E{Provider outcome and effect evidence}
  E -->|Completed and caller accepted| S[Persist session and acknowledge exact receipts]
  E -->|Gap or compaction| R[Invalidate held Memory and redeliver on resume]
  E -->|Interrupted or uncertain effects| F[Retain recovery evidence and fence candidate replay]
  R --> P
  A --> C[Keeper finalization and checkpoint save]
  C --> D[Disk restore with original reasoning witness]
  D --> A
```

The diagram names boundaries examined in code and fixtures. It is not a record
of live end-to-end execution across every provider.

## Source and runtime evidence

The [retained evidence record](../evidence/2026-11-01-official-client-audit/2026-11-01-official-client-evidence-record.md)
contains the surface-by-surface source map, installed versions, primary links and
sanitized counts from 367557 complete system-log lines. It records the exact
captured prefixes and their digests; counts are log messages, not distinct failed
requests. Private conversation bodies and authentication are excluded.

Codex 0.166.0 was checked against installed stable and experimental app-server
schemas. Claude Code 2.1.316 was checked against CLI/SDK session and compaction
contracts. Antigravity 1.4.12 was checked against headless/resume documentation.
OpenRouter structured reasoning details and Ollama Cloud's `/v1` wire were read
separately from native Ollama's `/api/chat` wire. No additional P0–P2 was established
in the inspected Codex, Claude, OpenRouter or Ollama paths. This is bounded source
coverage, not a live provider certification.

Current Kimi primary references add the [model/endpoint contract](https://www.kimi.com/code/docs/en/kimi-code/models.html)
and [K3 multi-turn replay guide](https://platform.kimi.ai/docs/guide/kimi-k3-quickstart)
to the evidence record's [tool-call error reference](https://www.kimi.com/code/docs/en/kimi-code/error-reference.html).
They were read on 2026-11-01; confidence is High for the documented contract and
source comparison. Actual provider behavior was not newly measured.

The [GLM API reference](https://docs.z.ai/api-reference/llm/chat-completion)
also establishes the omitted thinking toggle's enabled default. The repair keeps
entirely omitted thinking requests unchanged. Antigravity's five documented
non-completed states retain partial responses as error evidence, never as a
completed answer. Independent review caught that nonretryable provider errors
could still trigger candidate fanout; the final repair marks unobserved native
effects as unavailable before projection, while preserving known effects.

## Verification boundaries

Changed OCaml syntax, embedded fixture syntax, TOML syntax, changelog fragments
and evidence-record format were checked locally. External coding sessions did
not run local Dune. Independent source review found and corrected the optional
mapper callback, missing constructor field, missing quota consumers and the
pre-acknowledgement response-loss path.

The initial `Test` run [41259335179](https://github.com/jeong-sik/masc/actions/runs/41259335179)
on `7e09573bb73df90e45beb70666d132434d667821` failed strict warning 4 in the new
terminal observers before behavioral success could be established. The observers
were replaced by one exhaustive handler shared by their direct consumers.

`Test` run [41259587089](https://github.com/jeong-sik/masc/actions/runs/41259587089)
on `f974b1d2241d07f92d9678a19fe27a0eafa5ad10` completed successfully: four GLM
suites, 235 cases. Later lower-layer Muse repairs do not change those selected
Agent Core source bytes. This remains targeted evidence for the stated SHA and
scope. Other exact-head run IDs, selected suites, conclusions and review state
are recorded in the PR descriptions as they become available; a queued run is
not a pass.

| Test run | Exact tested head | Observed evidence |
| --- | --- | --- |
| [41259848104](https://github.com/jeong-sik/masc/actions/runs/41259848104) | `4b388f51316ab5ed9fbce1260454f048a68f1fb8` | SUCCESS: OpenAI codec and Keeper disk checkpoint suites, 93 cases. Later lower-layer changes are test-only Muse repairs. |
| [41259801045](https://github.com/jeong-sik/masc/actions/runs/41259801045) | `a39f630e47f69be2d1ff0a85a58d0b2a4e267d2c` | FAILURE: six selected suites passed, 127 cases; three Muse stop assertions failed before resume. This was baseline fixture drift: caller acceptance rejects a repeated-tool stop while the fixture expected the adapter's intermediate result. |
| [41261288235](https://github.com/jeong-sik/masc/actions/runs/41261288235) | `5e3b61b848e1e9e4403b8ccf4a9768e547e712df` | SUCCESS: all 78 Muse cases after keeping adapter settlement separate and asserting caller rejection plus retained tool receipt. Production stop/effect guards are unchanged. |
| [41260409586](https://github.com/jeong-sik/masc/actions/runs/41260409586) | `d7139136cf45c4744bf75228ee6eeedd3151cb1d` | FAILURE: two exact recorded-Memory wire cases failed; nine suites reported success, 500 cases (Kimi 6, reasoning 58, streaming 42, retention 20, outbox 12, Codex 196, Claude 103, Antigravity 23, session store 40). A Codex callback assertion was logged despite the suite's successful exit; that fixture cannot certify the affected assertion until repaired. |
| [41261854222](https://github.com/jeong-sik/masc/actions/runs/41261854222) | `7cb26cc755ae4e801b390ca190373b1d7a334bbb` | FAILURE: four suites passed, 220 cases (Kimi replay/effort 9, provider config 142, reasoning replay 58, GLM coverage 11). Two OpenRouter catalog assertions failed. Native-test compilation then stopped at two new fixture references to the nonexistent Masc.Runtime_antigravity facade export; these were corrected to the directly linked Runtime_antigravity module. Unexecuted native suites are not passes. |
| [41262679047](https://github.com/jeong-sik/masc/actions/runs/41262679047) | `a52c4d149a9f6545401c3e07becc5a5dc12420d3` | Requested the corrected Codex protocol suite, including observer-failure propagation and operator interruption. Conclusion is recorded in PR #47030. |

Independent source reviews passed the integrated Muse head `5e3b61b848e1e9e4403b8ccf4a9768e547e712df`,
the final Antigravity layer `7cb26cc755ae4e801b390ca190373b1d7a334bbb`,
the Codex fixture delta `0ae2947cedf260bea4deab07db8aa8dbf43ed74f`,
and the original GLM/Kimi/inline deltas. Those statements cover the recorded
source differences, not compilation, formal GitHub approval or live execution.

The Codex warning was a pre-existing fixture mistake: its first delta opened the
release gate correctly, but its later completion delta repeated a pre-settlement
assertion after all three tool responses were already read. The final serial
order was correct. The fixture now retains ordinary observer failures through
cleanup, while explicit operator interruption and Eio cancellation retain their
production semantics. No scheduling defect was established by that warning.

The selected verification paths include actual protocol fixtures, scoped runtime
materialization, Memory redelivery, receipt retention/ACK, checkpoint disk restore
and the next request serializer. They do not replace full regression, installed
binary verification, live ten-turn canaries or long-duration failover measurement.
No running Keeper, runtime-owned configuration, billing setting or service was
changed by this audit.

## Remaining findings

- [#47010](https://github.com/jeong-sik/masc/issues/47010) and [#47011](https://github.com/jeong-sik/masc/issues/47011) now have source repairs in #47026 and #47025. They remain open until the draft stack is reviewed and merged.
- [#47021](https://github.com/jeong-sik/masc/issues/47021): Live custom Kimi API IDs differ from documented IDs and unknown-model replay is unproven. The tracked effort declaration is repaired in #47024. Operator-owned model IDs and actual served identity were not changed or verified.
- [#47028](https://github.com/jeong-sik/masc/issues/47028): Generic/operator-defined Anthropic HTTP configurations do not represent account/linkage identity in durable reasoning source equivalence. Sonnet/Haiku 5.5 blocks can be dropped by an unrelated account while the request succeeds. Existing transformation logging is a partial mitigation; the shipped bindings use Claude Code instead. This P2 needs trusted account or provider-transformation evidence; no deployed incident or safe account-policy repair was established.
- [#44154](https://github.com/jeong-sik/masc/issues/44154#issuecomment-6303936847): The recorded Memory wire fixture predates baseline #43810's `ordered_program_steps` field. The [offline byte witness](../evidence/2026-11-01-official-client-audit/memory-wire-baseline.json) reproduces the exact failed request digest by adding only the missing empty-list field, 27 bytes. Relevant producers, test and historical corpus are unchanged by this audit. Fresh real provider evidence is required for the new request; historical responses and exact-wire assertions are preserved. Memory semantic success is not established by that failing suite.

These issues include symptoms, reproduction conditions, suspected causes and the
checks performed. The runtime observations are retained independently from the
source repairs; historical overflow, subscription exhaustion or an HTTP 402 is
not claimed cured by source review.
