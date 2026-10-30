# JSONL Contract Inventory

Status: reference
Scope: current JSONL writer substrates and store inventory under `<base-path>/.masc/`.

## Writer Substrates

| Substrate | Current contract | Used for | Evidence |
| --- | --- | --- | --- |
| `Fs_compat.append_jsonl` | Creates parent dir, serializes appends through a per-path `Stdlib.Mutex`, opens a fresh fd per call, writes `json + "\n"`, closes fd. No fsync. | Single-file append stores and `Dated_jsonl` day files. | `lib/fs_compat/fs_compat.ml` |
| `Fs_compat.append_file` | Shares the same per-path mutex registry as `append_jsonl`, but accepts raw string content. | Board posts/comments/votes, keeper single-file logs via support helpers. | `lib/fs_compat/fs_compat.ml`, `lib/keeper/keeper_types_support.ml` |
| `Dated_jsonl` & `Dated_jsonl.Store` | Date-split `base_dir/YYYY-MM/DD.jsonl`, base-dir mutex registry, append guard hook, recent/range reads, malformed JSON read skip. Appends delegate to `Fs_compat.append_jsonl`. `Dated_jsonl.Store` registers date-sharded stores so the daily maintenance loop prunes them under a single `MASC_JSONL_RETENTION_DAYS` (`[maintenance] jsonl_retention_days`, default `30` days) policy. | Audit, telemetry, tool usage, keeper receipts, tool calls, runtime events, gate events, verifications, board dated posts, activity graph. | `lib/dated_jsonl/dated_jsonl.ml` |
| `Keeper_types_support.append_jsonl_line` | Optional size rotation, UTF-8 repair, then raw `Fs_compat.append_file`. | Keeper memory/decision/policy/feedback/manifest single-file logs. | `lib/keeper/keeper_types_support.ml` |

## Store Inventory

| Store family | Runtime path contract | Writer | Reader / projection | Current schema owner | Notes |
| --- | --- | --- | --- | --- | --- |
| Audit log | `.masc/audit/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` (`Dated_jsonl.Store`) | `Dated_jsonl.read_recent` | `Audit_log.entry_to_json` / parser | Shared store per base dir; pruned by `MASC_JSONL_RETENTION_DAYS`. |
| Telemetry | `.masc/telemetry/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` (`Dated_jsonl.Store`) | `Dated_jsonl.read_recent`, parse/drop metrics | `Telemetry_eio.event_record_to_yojson` | Pruned by `MASC_JSONL_RETENTION_DAYS`. |
| Tool usage | `.masc/tool_usage/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` (`Dated_jsonl.Store`) | `Dated_jsonl.read_recent` and coverage-gap path on failures | `Tool_usage_log.record_to_json` | Pruned by `MASC_JSONL_RETENTION_DAYS`. |
| Keeper tool calls | `.masc/tool_calls/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` (`Dated_jsonl.Store`) after UTF-8 sanitization | Dashboard/tool-call readers | `Keeper_tool_call_log` record builders | Sanitizes tool output before append; pruned by `MASC_JSONL_RETENTION_DAYS`. |
| Keeper receipts | `.masc/keepers/<name>/execution-receipts/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` | `Dated_jsonl.read_recent store 1` for latest receipt | `Keeper_execution_receipt.to_json` | Receipt append also drives reaction ledger/operator broadcast side effects. |
| Keeper metrics | `.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` | dashboard/status detail readers | `Keeper_unified_metrics`, heartbeat snapshots | Per-Keeper byte cap via `[metrics] store_max_bytes`. |
| Keeper single-file logs | `.masc/keepers/<name>.memory.jsonl`, `.decisions.jsonl`, `.feedback.jsonl`, `.tla-trace.jsonl` | `Keeper_types_support.append_jsonl_line` | keeper memory/status/recall/detail readers | Per-keeper modules | Preserves rotation (`[metrics] max_bytes` / `max_rotated`) and UTF-8 repair. |
| Board posts/comments/reactions/sub-boards | `.masc/board_posts.jsonl`, `board_comments.jsonl`, `board_reactions.jsonl`, `board_sub_boards.jsonl` | create-only append for new rows; snapshot rewrite via `save_file_atomic` for mutation flushes | `Board` load/list, `Activity_feed` projections | `Board` serializers | Snapshot-like JSONL files after mutation. |
| Board votes | `.masc/board_votes.jsonl` | append on cast; snapshot rewrite on flush | board vote state and analytics | `Board_votes` | Snapshot rewrites preserve the cast timestamp. |
| Goal verification events | goal verification event path from `Goal_verification.events_path` | `Fs_compat.append_jsonl` | goal verification state/readers | `Goal_verification.emit_event` | Event append is separate from file-locked state update. |
| Trajectory | `.masc/trajectories/<keeper>/<trace_id>.jsonl` | `Fs_compat.append_jsonl` | trajectory affinity/status readers | `Trajectory.entry_to_json`, thinking and summary encoders | Append-only per `(keeper, trace_id)`. |
| Runtime/agent core events | `.masc/agent-core-events/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` (`Dated_jsonl.Store`) | dashboard runtime/agent core projections | `Runtime_event_bridge`, `Runtime_trust_persist` | Pruned by `MASC_JSONL_RETENTION_DAYS`. |

## Contract Invariants

1. `Fs_compat.append_jsonl` and `Fs_compat.append_file` serialize mixed writes to the same path with one per-path mutex registry.
2. `Dated_jsonl.open_store` instances for equivalent base dirs share the same mutex, including trailing-slash variants.
3. `Dated_jsonl.append` writes through `Fs_compat.append_jsonl`, keeps `YYYY-MM/DD.jsonl`, and does not poison the base-dir mutex after append failure.
4. `Dated_jsonl.read_recent`, `iter_all`, and `read_range` skip malformed JSON lines instead of failing the whole read.
5. Keeper single-file helpers preserve rotation and UTF-8 repair before delegating to `append_file`.
6. Board post/comment/reaction JSONL files remain snapshot files after mutation flush, while create paths may append.
7. Board vote rows preserve the original cast timestamp across append and rewrite.
8. Goal verification event append remains separate from file-locked request-state mutation.
9. Trajectory append stays per `(keeper, trace_id)` path and remains append-only.
