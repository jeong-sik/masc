# Changelog


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
