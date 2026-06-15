# RFC-0238 caller context — keeper-store retention (empirical grounding)

Companion evidence for RFC-0238. Records the measurement that reframed the
target away from the audit's named stores, so a reviewer can verify the
premise.

## Measurement (2026-06-15, live base_path = /Users/dancer/me/.masc)

The 2026-06-13 merge audit's F942/F943 named "Memory OS / external-attention
unbounded growth". Measured on the live store:

| store | path | size | status |
|-------|------|------|--------|
| Memory OS facts | `keepers/<id>.facts.jsonl` | absent (0) | RFC-0231 abandoned (PR #20829 CLOSED), never written |
| Memory OS events | `keepers/<id>.events.jsonl` | absent (0) | same |
| Memory OS episodes | `keepers/<id>/episodes/` | absent | same |
| external attention | `attention/<keeper>.jsonl` | dir absent (0) | Discord inbound never recorded |
| `<keeper>.memory.jsonl` | keepers/ | 36–56K each | small, fine |
| **`<keeper>.decisions.jsonl`** | keepers/ | **9.7M / 9.1M / 9.1M / 8.8M …, total keepers dir 1.4G** | **real unbounded grower** |

Conclusion: the audit findings point at stores with zero production data. The
actual unbounded growth is `<keeper>.decisions.jsonl`.

## decisions.jsonl shape

- Writer: `append_tool_exec_decision_log` (`lib/keeper/keeper_tools_oas_handler_telemetry.ml:102`)
  → `Keeper_types_support.append_jsonl_line` (`lib/keeper/keeper_types_support.ml:160`)
  to a single flat per-keeper file. One line per tool execution. No rotation,
  no partitioning → unbounded.
- Readers already tail-bound: `keeper_accountability.tail_decision_log_lines_or_empty`
  reads last 500KB / 128 lines; dashboard feeds/snapshot read bounded slices.
  So dropping old head entries is safe for current readers.

## Reusable substrate

`lib/dated_jsonl/dated_jsonl.mli` already provides the retention primitive:
- `val append : t -> Yojson.Safe.t -> unit` (date-partitioned)
- `val prune : t -> days:int -> int` (drop partitions older than N days)
- `val read_recent`, `read_range`, `load_tail_lines`, `count_entries`, mutex.

Phase-1 = migrate decisions.jsonl writer/readers to Dated_jsonl + prune. The
framework wraps store registration + a typed policy + the periodic sweep.

## RFC-0231 lessons (the abandoned design)

PR #20829 (CLOSED) proposed tiered Memory OS with a forgetting curve
(`decide_retention score`, exponential recency half-life) + caps
(`default_max_facts = 8`, `default_max_episodes = 2`). The `decide_retention`
function was never wired (caller 0) and was deleted in #21125. The caps/curve
model is sound for semantic memory and is carried into the framework as the
`Capped_by_score` policy — but defined-only until the Memory OS store is live.
