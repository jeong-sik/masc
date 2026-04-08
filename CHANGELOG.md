# Changelog


## [2.261.0] - 2026-04-08

### Added
- Per-keeper provider filter via `allowed_providers` config (#5831)
- Preset-aware task routing — keepers only claim tasks matching their preset (#5820)
- 11-state keeper phase diagram in dashboard (#5829)
- Excuse patterns editor UI with server-side validation (#5818)
- Output validation stats in tool-quality dashboard (#5832)
- Dashboard SSE `keeper_tool_skipped` event + centralized thresholds (#5824)
- Deterministic tool output validation (Samchon-style schema constraints) (#5821)
- Analyst persona (verification-driven) (#5850)

### Fixed
- Comprehensive Eio.Cancel.Cancelled guard sweep — 72 files, 129 patterns (#5842)
- Cancelled guard rollback for 3 cleanup sites (fd close before re-raise) (#5848)
- AllowList pruning WARN + agent JSON race condition (atomic write) (#5840)
- Defensive lowercase + warn log in filter_by_providers (#5846)
- Policy preset name validation at load time (#5787)
- Cluster-aware telemetry read path (#5828)
- Chevron discoverability (opacity-40 default) (#5837)

### Changed
- Board_listener removed — filesystem-first, PG relay redundant (#5809)
- Heuristic metadata matching replaced with deterministic Tool_dispatch sets (#5830)
- DRY `lower_string_list_opt` helper for allowed_providers parsing (#5844)
- Transport status reports canonical HTTP protocol (#5833)

### Docs
- Gate-Connector Protocol RFC: fail-closed, shorter URL TTL, replay protection (#5805)

## [2.260.0] - 2026-04-08

### Fixed
- Eio.Cancel.Cancelled re-raised instead of swallowed in bridge, dashboard, and metrics modules (#5810)
- truncate_tool_output now enforces hard cap on total output length (#5814)
- autonomous_turn_limit default set to 1 for single-slot servers (#5806)
- Yojson.Json_error catch narrowed in dashboard tool-quality (#5812)
- Branch-switch guard hardened with tab tokenization, global git options, and precise mutation detection (#5813)
- useEffect void prefix for floating promise lint (#5816)

### Changed
- All remaining failwith usages replaced with explicit raise (Failure ...) (#5811, #5817)
- Excuse patterns decoupled into configurable JSON file (#5808)
- Adaptive thinking review: retry triggers high thinking, soft-error scan removed from Ok variants (#5815)

## [2.259.0] - 2026-04-08

### Added
- **Discovery time-series** -- record each probe result to `.masc/discovery/YYYY-MM/DD.jsonl` via Dated_jsonl. (#5781)
- **Per-model inference metrics** -- `GET /api/v1/models/metrics?window=30` aggregates tok/s, latency, tokens by model from decisions.jsonl. (#5784)
- **Provider discovery merge** -- `/api/v1/providers` now includes OAS Discovery probe data (model, ctx_size, slots, health). (#5778)
- **Config-driven shell write gate** -- `permissions.shell_write_presets` in tool_policy.toml replaces hardcoded variant match. (#5782)
- **Config-driven workflow gate** -- `permissions.workflow_presets` in tool_policy.toml replaces hardcoded variant match. (#5777)
- **Log.Discovery** -- structured logging module for discovery subsystem.

### Fixed
- **Team session projection** -- `collaboration_context` and `Prompt_composer` fill lossy 47-to-12 field gap. (#5783)

### Changed
- **OAS pin** -- bumped to v0.114.0 for cascade failover parse crash fix. (#5785, #5786, #5788)
- **Gate-Connector RFC** -- refined transport interfaces to deep-dive format. (#5780)
- **Tool search** -- returns `already_visible` tool names in response. (#5779)

## [2.258.0] - 2026-04-08

### Added
- **Transport_bridge** -- unified provider interface for SSE/WS/gRPC/WebRTC with seal-after-bootstrap safety and aggregate metrics. (#5726, #5735, #5744)
- **Keeper OAS bridge** -- structured Eio cancellation for proactive/autonomy calls. (#5738)
- **Shannon entropy tool diversity** -- signal to detect repetitive tool use patterns. (#5752)
- **Autoboot retry** -- configurable retry loop for keepers that fail initial startup (env: `MASC_KEEPER_BOOTSTRAP_RETRY_MAX`, `MASC_KEEPER_BOOTSTRAP_RETRY_INTERVAL_SEC`). (#5736, #5753)
- **Inference telemetry** -- tok/s, cache hits, reasoning tokens recorded to decisions.jsonl and costs.jsonl. (#5714)
- **TLA+ specs** -- KeeperTurnCycle 7-state model, KeeperContextLifecycle with QCheck PBT. (#5716, #5720, #5728)
- **.mli for keeper_exec_\*** -- interface files for 8 split modules (board, fs, github, masc, memory, shell, task, voice). (#5755)

### Fixed
- **9B model guidance** -- schema-first tool descriptions, aligned find param, blocked chaining ops (&&/||/;), improved error messages with examples. (#5737, #5751, #5756)
- **Board idempotency** -- `Post_not_found` and `Already_voted` treated as success instead of failure. (#5748, #5754)
- **Cascade config** -- split default/keeper models, correct `keeper_unified_models` key, concrete model IDs. (#5724, #5727)
- **Keeper keepalive** -- secondary timeout for stuck fibers, trace_emit path fix. (#5736, #5759)
- **Janitor tools** -- added `tasks_audit` and `shell_readonly` to allowed list. (#5749)
- **Version truth** -- auto-bump now updates all version files. (#5747)

### Changed
- **OAS pin** -- bumped to include `accept_on_exhaustion` and Ollama ctx fix. (#5760)
- **Room task** -- flattened `claim_task_r` and `transition_task_r` using `let*` bindings. (#5725)
- **Ollama provider** -- added as first-class provider kind. (#5742)

## [2.257.0] - 2026-04-07

### Removed
- **Collaboration module references** -- OAS boundary violation cleanup. Delete team_context_oas_adapter, dashboard_collaboration_evidence, related tests/harness/routes (-1916 lines).

### Changed
- **OAS agent_sdk pin** -- bump to >= 0.111.0 (Collaboration.t removed, collaboration_context opaque JSON).

## [2.256.0] - 2026-04-07

### Changed
- **OAS agent_sdk pin** -- bump 0.110.0 to 0.111.0 (ollama provider).

## [2.255.0] - 2026-04-07

### Added
- **TopK_llm tool selection** -- activate OAS Tool_selector.TopK_llm in keeper
  before_turn_hook. 2-stage selection: BM25 pre-filter then LLM reranking via
  `default_rerank_fn`. Gated by `MASC_KEEPER_LLM_RERANK=true` (default off).
  Self-healing fallback to BM25 on LLM failure. 8 new tests.

## [2.254.0] - 2026-04-07

### Added
- **Post-turn evidence capture** -- execution context tracking for keeper decisions. (#5621)
- **Anti-polling gate** -- boring-tool gate to break keeper polling loops. (#5623)
- **TF-IDF synonym expansion** -- 39 more tool synonyms for prefilter. (#5628)
- **OAS Event Bus pipeline** -- connect OAS telemetry to keeper Agent.run. (#5641)
- **Runtime params dashboard** -- migrate 25 keeper params to Runtime_params. (#5640)
- **Silent failure logging** -- error visibility in hotspots. (#5632)
- **Startup readiness gate** -- keeper_up returns structured error with retry_after_ms when server not ready. (#5608)
- **Telemetry in decision records** -- add telemetry block to keeper decision records. (#5617)
- **Cross-keeper file collision detection** -- process-scoped tracker warns when two keepers modify the same file within 300s. (#5621)

### Changed
- **OAS agent_sdk pin** -- bump 0.109.0 to 0.110.0 (inference telemetry, tool_choice propagation, watermark compaction). (#5639)
- **tool_shard** -- replace Hashtbl with immutable StringMap. (#5593)
- **Anti-polling gate simplification** -- per-review refactor. (#5645)
- **Keeper_event_bus module** -- extracted from Keeper_keepalive to break dependency cycles. (#5641)
- **Cache deduplication** -- deduplicate read+parse via read_entry_file. (#5647)

### Fixed
- **keeper_agent_sender mismatch** -- unified to meta.agent_name, fixing task release/cancel failures. (#5625, #5629)
- **code_search error messages** -- include exit code, default to literal match. (#5630, #5634)
- **Keeper status fallback** -- file-read recovery hints, subprocess stderr. (#5595)
- **Compaction unblock** -- when reflection_ts=0 or ratio>=0.8. (#5600)
- **Core discovery tools** -- add masc_web_search and shell_readonly. (#5622)

### Infrastructure
- **Vite bump** -- 6.4.1 to 6.4.2. (#5624)
- **.ci_build/ gitignore**. (#5643)

## [2.253.0] - 2026-04-07

### Added
- **Memory consolidation** -- short-term to long-term memory transfer. (#5588)
- **SearXNG web search** -- add web search tool for keepers. (#5591)
- **Slot pinning** -- llama-server KV cache reuse via slot_id. (#5583)
- **Self-directed autonomy triggers** -- token budget fix and autonomy. (#5594)
- **Per-turn wall-clock timeout** and slot yield. (#5603)

### Changed
- **Autonomous multi-step behavior** -- enable keeper multi-step. (#5592)
- **Default max_turns** -- 50 to 200 for autonomous PR workflow. (#5585)

### Fixed
- **extend_turns API** -- replace internal Agent.set_state with public API. (#5580)
- **Transient vs persistent failure** -- separate turn failure counting. (#5584)
- **stderr capture** -- capture in run_argv_with_status. (#5586)
- **fs_read hint** -- add parent directory hint on file-not-found. (#5589)

### Performance
- **Server-side cache** for keeper_status responses. (#5587)
- **mtime-based guard** -- skip meta disk read when mtime unchanged. (#5590)
