# Official client and provider continuity audit — 2026-11-01

Five concrete contract defects were found and repaired in draft Native Stack
[47014](https://github.com/jeong-sik/masc/pull/47022). The review followed current
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

The Kimi change deliberately uses the three shipped model bindings. It does not
guess capabilities for arbitrary operator-created model IDs. Its six fixture
cases retain synthetic reasoning carriers through production code; they do not
certify a provider-reported model identity or live account access.

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

The selected verification paths include actual protocol fixtures, scoped runtime
materialization, Memory redelivery, receipt retention/ACK, checkpoint disk restore
and the next request serializer. They do not replace full regression, installed
binary verification, live ten-turn canaries or long-duration failover measurement.
No running Keeper, runtime-owned configuration, billing setting or service was
changed by this audit.

## Remaining findings

- [#47010](https://github.com/jeong-sik/masc/issues/47010): Antigravity's decoder accepts only two of the documented result statuses.
- [#47011](https://github.com/jeong-sik/masc/issues/47011): Explicit GLM full-history preserved thinking with an omitted thinking toggle needs effective-default reconciliation.
- [#47021](https://github.com/jeong-sik/masc/issues/47021): Live custom Kimi API IDs differ from documented IDs, unknown-model replay is unproven, and explicit effort declarations need reconciliation. Shipped K3 defaults omit the effort field; they do not force the `none` value.

These issues include symptoms, reproduction conditions, suspected causes and the
checks performed. The runtime observations are retained independently from the
source repairs; historical overflow, subscription exhaustion or an HTTP 402 is
not claimed cured by source review.
