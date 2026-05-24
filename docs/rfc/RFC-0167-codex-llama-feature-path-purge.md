# RFC-0167 CLI-Tool-B omission-dedup + Llama endpoint-discovery feature-path purge

| | |
|---|---|
| Status | Draft |
| Supersedes-in-part | RFC-0166 §9 (deferred items) |
| Related | RFC-0165 (auth client-agnostic), RFC-0166 (big-bang sweep rev1+rev2) |
| Scope | `lib/cascade/cascade_transport_codex_omission_dedup.{ml,mli}`, `lib/cascade/cascade_transport.{ml,mli}` facade + caller, `lib/cascade/cascade_config_provider_filter.ml`, `lib/cascade/cascade_metrics.{ml,mli}`, `test/test_cli-tool-a_omission_dedup_10097.ml` |
| Repos | masc-mcp |

## 1. Problem

RFC-0166 (rev1 + rev2) cleared all client/provider name literals from `lib/` and `bin/` source except for two feature paths held back in §9 because removing them in that PR would have cut the feature itself:

1. `cascade_transport_codex_omission_dedup` (#10097): a 5-function module that fingerprints per-keeper cli-tool-a MCP-tool omissions and emits WARN-dedup + per-tool Prometheus counter.
2. `cascade_config_provider_filter.ml:38` `Some ("llama", model_id)`: model-aware endpoint resolution for Llama labels, with a round-robin fallback to `Llm_provider.Provider_registry.current_llama_endpoint`.

The operator deferred §9 explicitly and confirmed in the follow-up turn that both should be removed. This RFC closes them.

## 2. Decision

### Agent-Code omission-dedup
- Delete `lib/cascade/cascade_transport_codex_omission_dedup.{ml,mli}` wholesale.
- Delete the 5 facade re-exports in `cascade_transport.{ml,mli}` (`cli-tool-a_omission_fingerprint`, `cli-tool-a_omission_fingerprint_seen`, `record_cli-tool-a_omission`, `record_cli-tool-a_omission_for_agent`, `reset_cli-tool-a_omission_dedup_for_tests`).
- Delete `test/test_cli-tool-a_omission_dedup_10097.ml` (paired test, exclusive caller of the facade).
- Reword the one internal caller in `cascade_transport.ml` to client-agnostic names: `codex_can_auth_keeper_bound_actor_tools` → `provider_can_auth_keeper_bound_actor_tools`, `codex_keeper_bound_actor_tools` → `omitted_keeper_bound_actor_tools`. The `record_cli-tool-a_omission_for_agent` call at line 239 is removed; the structural omission detection that returns `Error (invalid_runtime_config ...)` remains intact.

### Llama endpoint discovery
- Delete the `Some ("llama", model_id) -> ...` arm from `Cascade_config_provider_filter.resolve_label_context`. The function now resolves discovery-based per-slot context only for `"custom:<url>"` labels.
- Delete `Cascade_metrics.on_llama_model_not_discovered` + the `metric_llama_model_not_discovered` constant + its `.mli` export. The counter had no remaining caller.

## 3. Behavioral consequences (operator-acknowledged)

| Path | Before | After |
|------|--------|-------|
| `cascade.toml` with `"llama:<model_id>"` label, no `Discovery.context_for_model` match | Fell back to `current_llama_endpoint` round-robin and ticked `masc_cascade_llama_model_not_discovered_total` | `resolve_label_context` returns `None`. Per-slot context resolution must use `"custom:<url>"` label shape instead. |
| `cascade.toml` with `"llama:<model_id>"` label, has Discovery match | Returned `Some ctx` | Returns `None`. |
| cli-tool-a runtime adapter omits keeper-bound MCP tools (per-keeper bridging required, no per-keeper bearer) | Logged WARN-once + ticked per-tool counter + (if `required`) returned `Error (invalid_runtime_config ...)` | Same `Error` path retained; WARN + counter removed. |
| Test `test_cli-tool-a_omission_dedup_10097` | Validated WARN-once + counter semantics | Removed; the validated behavior no longer exists. |

The Llama discovery removal is a *feature removal*. The agent-code omission-dedup removal is an *observability removal* — the structural error detection (the part that affects runtime behavior) is unchanged.

## 4. Domain boundary closure

After this RFC, `lib/` and `bin/` source contain zero MCP-client or upstream-provider name literals except for RFC-0166 / RFC-0167 closeout comments that historically cite the swept names (self-documenting). The remaining `agent-llm-a` / `provider-f` / `agent-code` / `llama` hits in the repository live in:

- `docs/` (history, audit reports, runbooks)
- `dashboard/src/` (frontend)
- `test/` fixtures other than the deleted agent-code omission dedup test

Those are out of scope for this RFC.

## 5. Workaround-rejection self-check

This RFC removes; it does not add.

1. "makes X visible" without fixing — NO (removes telemetry without adding any).
2. String/substring/prefix classifier added — NO.
3. "PR #N fixed K of M sites" — NO (closes RFC-0166 §9's deferred-K-of-M explicitly).
4. catch-all `_ ->` added — NO (`Some (_, _)` arm preserved; it was already there).
5. cap / cooldown / dedup / repair — NO (removes a dedup; does not add one).
6. test backdoor — NO (removes a test that only existed to validate the now-removed dedup).
7. typo / off-by-one repeated — NO.

All 7 rejection signatures: NO.

## 6. Verification

- `dune build lib/ bin/` clean.
- `rg 'cli-tool-a_omission|on_llama_model_not_discovered|Some \("llama"' lib/ bin/` returns only RFC-0167 closeout comments.
- `rg -i 'agent-llm-a|provider-f|agent-code|provider-c|provider-a|provider-k|llama' lib/ bin/` returns only:
  - RFC-0166 / RFC-0167 closeout comments (self-documenting).
  - `cascade_metrics.ml` describing how `cascade.toml` `"llama:..."` labels behaved before the removal (operator-facing release note context, kept in comment form pending a separate docs sweep).
  - `coord/nickname.ml` `"llama"` animal name (false positive).

## 7. Migration

Operators must:

- Replace any `cascade.toml` cascade entries of the shape `"llama:<model_id>"` with `"custom:<endpoint_url>"` (the generic discovery-based label).
- Drop Grafana queries against `masc_cascade_llama_model_not_discovered_total` (series no longer emitted).
- The structural cli-tool-a WARN/counter is gone; rely on the `tool_support` `Error` path for required-tool omissions on cli-tool-a transports.
