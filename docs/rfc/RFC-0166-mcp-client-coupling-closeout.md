# RFC-0166 MCP-client coupling closeout (big-bang)

| | |
|---|---|
| Status | Draft |
| Supersedes | RFC-0058 Phase 5.7 (now marked Superseded) |
| Related | RFC-0165 (auth modules — the first half), RFC-0042 closed-sum |
| Scope | All remaining MCP-client name literals in OCaml dispatch/text surfaces |
| Repos | masc-mcp |

## 1. Problem

After RFC-0165 (#18203, merged 2026-05-24) removed the `agent-llm-a`/`provider-f` dispatch from `lib/auth_login.ml` and `lib/auth_doctor.ml`, an audit of the rest of the codebase found that MCP-client name literals still leaked into a handful of operator-facing tool descriptions in `bin/gen_tool_descriptors.ml`. The descriptions enumerated specific client names (`'agent-llm-a', 'provider-f', 'agent-code', or 'llama'`) as if the server held a closed roster of supported clients, when in fact `agent_name` is a free-form string resolved against an operator-configured roster.

This RFC closes the residue and records the domain boundary that distinguishes legitimate from illegitimate retention of client/provider names.

## 2. Decision

**Sweep**: Replace the enumerated client lists in tool descriptions with descriptions that frame `agent_name` as free-form, naming the operator's local roster as the source of truth.

**Retain (Non-Goals)**: Upstream LLM provider classification (`apply_provider_filter`, `inference_model_bucket`) is a *different domain* — it classifies the LLM API endpoint (Provider-A, Provider-D, Provider-F, etc.) that MASC *calls*, not the MCP client that *calls MASC*. These belong to the cascade/provider layer and stay in this PR's Non-Goals.

**Wire-format adapters (Non-Goals)**: `cascade_transport_codex_omission_dedup.ml` and similar `*_adapter.ml` files encode protocol-level quirks of specific provider wire formats. RFC-0058 §3 lists these as non-goals; this RFC preserves that carve-out.

## 3. Why "closeout" rather than further dispatch sweep

The big-bang inventory (2026-05-24) measured:

| Area | Hits | Disposition |
|------|------|-------------|
| `lib/auth_login.ml`, `lib/auth_doctor.ml` | 0 | Cleared by RFC-0165 |
| `lib/codex_mcp_config_doctor.ml` | n/a | File already removed |
| `lib/server/server_runtime_bootstrap.ml` agent-code hits | 0 | Already clean |
| `bin/gen_tool_descriptors.ml` MCP-client examples | 5 | Cleared (description text → free-form) |
| `lib/cascade/cascade_config_provider_filter.ml` comment | 1 | Cleared (comment rewritten) |
| `lib/cascade/cascade_config.mli`, `cascade_config_loader.ml`, `cascade_config_parser.ml`, `cascade_observation.{ml,mli}` JSON/docstring examples | ~6 | Cleared |
| `lib/cascade/cascade_event_bridge_inference.ml` `inference_model_bucket` | substring classifier | Body collapsed to `"upstream"` (label cardinality = 1) |
| `lib/cascade/cascade_config_builder.ml` `binding.command = "agent-code"` dispatch | 1 | `provider_requires_argv_prompt_preflight` always returns `false` (legacy agent-code preflight path effectively disabled) |
| `lib/notify.ml` agent emoji roster (`agent-llm-a`/`provider-f`/`agent-code`/`llama`) | 4 | Roster emptied; operators register via `register_agent_emoji` |
| `lib/voice/voice_runtime_overlay.ml` default voice mapping | 6 | Mapping emptied; operators supply via voice_bridge_core config |
| `lib/exec/exec_program.ml{,.mli}` `known` variant `Agent-LLM-A | Provider-F | Agent-Code` | 3 ctors | Variants removed from closed-sum + reverse lookup |
| `lib/tool_call_replay_harness.ml` snapshot canonical roster | 10 names | Closed-roster removed; accepts any non-empty canonical |
| `lib/prometheus.ml`, `lib/prometheus_builtin_metric_names.ml` description example | 2 | Comment rewritten (`provider="<provider_slug>"`) |
| `lib/relay.ml`, `lib/coord/coord_query.ml`, `lib/coord/nickname.ml`, `lib/dashboard_cascade.mli`, `lib/provider_kind_resolver.mli`, `lib/metrics_store_eio.mli` docstring/comment | ~10 | Comments rewritten to placeholder syntax |
| `cascade_transport_codex_omission_dedup.ml` (wire adapter) | (module) | Kept; full removal would cut the cli-tool-a transport path entirely and is out of single-PR scope. Tracked in §9 |
| `lib/cascade/cascade_config_provider_filter.ml:38` `Some ("llama", ...)` Llama discovery dispatch | 1 | Kept; removing it disables Llama endpoint discovery as a feature. Tracked in §9 |

The "Non-Goal" carve-out from the previous revision of this RFC is rescinded: the operator explicitly requested "전체 폭파, 어차피 레거시 지원 안할거임" after seeing the carve-out, so the upstream-provider classifier (`inference_model_bucket`) and the emoji/voice/exec `known` rosters were swept as well.

## 4. Changes

See §3 inventory for the per-file disposition. In summary:

- Comment / docstring / Prometheus-description / RFC-document text rewrites in ~10 files (no behavior change, free-form placeholder syntax).
- `bin/gen_tool_descriptors.ml`: 5 tool descriptions reframed to free-form `agent_name`.
- `lib/cascade/cascade_event_bridge_inference.ml`: substring classifier collapsed to single `"upstream"` bucket.
- `lib/cascade/cascade_config_builder.ml`: `provider_requires_argv_prompt_preflight` always `false` (legacy agent-code preflight disabled; helper family retained for downstream wiring of cascade-decl `argv_prompt_preflight` capability flag).
- `lib/notify.ml`: agent emoji table starts empty; operator extends via `register_agent_emoji`.
- `lib/voice/voice_runtime_overlay.ml`: default per-agent voice mapping empty.
- `lib/exec/exec_program.ml{,.mli}` + `bin/gen_shell_ir_walkers.ml`: `Agent-LLM-A | Provider-F | Agent-Code` removed from the `known` closed-sum and its reverse lookup + the generated walkers template.
- `lib/tool_call_replay_harness.ml`: snapshot canonical roster removed; accepts any non-empty canonical.
- `docs/rfc/RFC-0058-phase-5-7-doctor-modules.md`: Status `Draft` → `Superseded by RFC-0165 + RFC-0166 (2026-05-24)`. Closeout note explains the three Phase-5.7 target files reached the goal by independent paths.

## 5. Domain boundary

The previous revision of this RFC drew a three-way boundary (MCP client / upstream LLM provider / wire-format adapter) and retained the latter two as legitimate domain knowledge. The operator rescinded that carve-out: in this codebase neither upstream-provider enumeration nor MCP-client enumeration belongs in source. Closed rosters that survive belong to feature paths the operator chose to retain explicitly (Llama endpoint discovery; cli-tool-a transport adapter) — see §9.

## 6. Workaround-rejection self-check (`software-development.md` §워크어라운드 거부 기준)

This RFC removes; it does not add.

1. "makes X visible" without fixing — NO
2. String/substring/prefix classifier added — NO (removes the residue of the one RFC-0165 closed)
3. "PR #N fixed K of M sites" — NO (the unfinished N-of-M is *this* RFC's reason to exist; closing it now)
4. catch-all `_ ->` added — NO
5. cap / cooldown / dedup / repair — NO
6. test backdoor — NO
7. typo / off-by-one repeated — NO

All 7 rejection signatures: NO.

## 9. Out-of-PR scope (explicit deferral)

Two feature paths retain a client/provider-name literal because removing them in this PR would have cut the feature itself:

- `cascade_transport_codex_omission_dedup.ml` (entire module + its facade in `cascade_transport.ml`): tracks per-agent cli-tool-a tool-omission fingerprints for WARN dedup. Its removal also removes the cli-tool-a transport path (`record_cli-tool-a_omission_for_agent` is called from the transport's bound-actor handling). Full removal needs a separate PR that decides whether cli-tool-a stays as a supported transport at all.
- `lib/cascade/cascade_config_provider_filter.ml:38` `| Some ("llama", model_id) -> ...`: Llama endpoint discovery (model-aware endpoint resolution + round-robin fallback). Removal disables Llama endpoint discovery as a feature.

Operator agreement: these two are tracked here for transparency; their removal is a separate PR. Until then they remain the only client/provider name literals in source (excluding RFC-0166 closeout comments that historically cite the swept names).

## 7. Verification

- `rg '"agent-llm-a(_code)?"|"provider-f(_cli)?"|"agent-code(_cli)?"|"provider-c(_cli)?"|"provider-a"|"provider-k(_coding|-coding)?"|MASC_AGENT-LLM-A|MASC_PROVIDER-F|MASC_AGENT-CODE' lib/ bin/` returns only RFC-0166 closeout comments (`cascade_event_bridge_inference.ml:25`, `voice_runtime_overlay.ml:150`, `cascade_config_builder.ml:81`) — self-documenting historical citations.
- `dune build lib/ bin/` clean.
- The `cascade_transport_codex_omission_dedup` and Llama endpoint discovery features are still wired (see §9).

## 8. Migration

Breaking changes — operators may need to take action:

- **Prometheus dashboards** that partition by `model_bucket` will see all rows collapse to `model_bucket="upstream"`. Per-model partitioning, if needed, must now consume the raw `provider`/`model` event fields directly rather than the server-coded bucket.
- **Notification emoji**: client-specific emoji are no longer baked in. Call `Notify.register_agent_emoji` from operator init code to restore.
- **Voice runtime**: `default_agent_voices` returns `[]`. Supply per-agent voices via `voice_bridge_core` config.
- **Exec sandbox `known` variant**: `agent-llm-a` / `provider-f` / `agent-code` binaries no longer have a closed-sum classification (they now fall through to the generic `unknown` path). If the sandbox previously relied on this classification, the operator must register them through the existing extension mechanism instead.
- **Replay harness**: previously rejected unknown provider canonicals; now accepts any non-empty canonical and treats it as Provider-D-compatible chat-completions.
- **cli_prompt_preflight**: always `None` until the cascade-decl `argv_prompt_preflight` capability flag is wired into `Cascade_runner.config`. Legacy agent-code preflight is effectively disabled.
