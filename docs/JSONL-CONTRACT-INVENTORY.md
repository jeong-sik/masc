# JSONL Contract Inventory

Status: refactor WBS task `task-381` for GitHub issue #16082.
Date: 2026-05-18.
Scope: current code inventory only. This document does not change runtime behavior.

## Goal

Create the contract map needed before moving audit, telemetry, board, runtime,
receipt, goal-event, and trajectory stores onto a smaller shared writer
adapter. The next task (`task-382`) should turn this inventory into focused
fixtures before any writer implementation is changed.

## Writer Substrates

| Substrate | Current contract | Used for | Refactor pressure | Evidence |
| --- | --- | --- | --- | --- |
| `Fs_compat.append_jsonl` | Creates parent dir, serializes appends through a per-path `Stdlib.Mutex`, opens a fresh fd per call, writes `json + "\n"`, closes fd. No fsync. | Single-file append stores and `Dated_jsonl` day files. | This is the strongest common low-level append primitive. Any new adapter should preserve its per-path mutex registry and fresh-fd behavior. | `lib/fs_compat/fs_compat.ml:135`, `lib/fs_compat/fs_compat.ml:591` |
| `Fs_compat.append_file` | Shares the same per-path mutex registry as `append_jsonl`, but accepts raw string content. | Board posts/comments/votes, keeper single-file logs via support helpers. | Callers manually build JSONL strings, so schema safety and UTF-8 policy vary by caller. | `lib/fs_compat/fs_compat.ml:156`, `lib/board_core.ml:495`, `lib/keeper/keeper_types_support.ml:165` |
| `Dated_jsonl` | Date-split `base_dir/YYYY-MM/DD.jsonl`, base-dir mutex registry, append guard hook, retention pruning, recent/range reads, malformed JSON read skip. Appends delegate to `Fs_compat.append_jsonl`. | Audit, telemetry, tool usage, keeper receipts, tool calls, runtime events. | This should remain the high-level date-split adapter, but store-level caches and failure policies are still duplicated. | `lib/dated_jsonl/dated_jsonl.ml:17`, `lib/dated_jsonl/dated_jsonl.ml:57`, `lib/dated_jsonl/dated_jsonl.ml:259`, `lib/dated_jsonl/dated_jsonl.ml:287` |
| `Jsonl_atomic` | Eio writer with per-canonical-path `Eio.Mutex`, scoped `fs`, long-lived sink, explicit close. | RFC-0107 style in-process writer. | Contract overlaps with `Fs_compat.append_jsonl` but uses a different fd lifetime and mutex registry. Keep only if a long-lived Eio writer is intentionally required. | `lib/jsonl_atomic/jsonl_atomic.ml:1`, `lib/jsonl_atomic/jsonl_atomic.ml:59`, `lib/jsonl_atomic/jsonl_atomic.ml:85` |
| `Keeper_types_support.append_jsonl_line` | Optional size rotation, UTF-8 repair, then raw `Fs_compat.append_file`. | Keeper memory/decision/policy/feedback/manifest style single-file logs. | This is a domain helper, not a general writer. New adapter should not erase its rotation/UTF-8 repair semantics by accident. | `lib/keeper/keeper_types_support.ml:30`, `lib/keeper/keeper_types_support.ml:84`, `lib/keeper/keeper_types_support.ml:139`, `lib/keeper/keeper_types_support.ml:165` |
| `Shared_audit.Store.append` | Date-split hash-chain envelope, direct `open_out_gen`, mutable `latest_hash`. | Shared audit chain. | This is the largest divergence: hash-chain ordering is domain-specific, but low-level append lacks the common writer contract. Needs fixtures before migration. | `lib/shared_audit/store.ml:1`, `lib/shared_audit/store.ml:85` |

## Store Inventory

| Store family | Runtime path contract | Writer | Reader / projection | Current schema owner | Notes |
| --- | --- | --- | --- | --- | --- |
| Audit log | `.masc/audit/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` | `Dated_jsonl.read_recent` | `Audit_log.entry_to_json` / parser | Cache is guarded so callers share a store per base dir. Structural parse failures are logged. |
| Telemetry | `.masc/telemetry/YYYY-MM/DD.jsonl`, legacy fallback for old file readers | `Dated_jsonl.append` | `Dated_jsonl.read_recent`, parse/drop metrics | `Telemetry_eio.event_record_to_yojson` | Mirrors audit cache invariant. |
| Tool usage | `.masc/tool_usage/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` | `Dated_jsonl.read_recent` and coverage-gap path on failures | `Tool_usage_log.record_to_json` | Has retention and coverage-gap fallback for init/append failures. |
| Keeper tool calls | `.masc/tool_calls/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` after UTF-8 sanitization | Dashboard/tool-call readers | `Keeper_tool_call_log` record builders | Explicitly sanitizes tool output before append. |
| Keeper receipts | `.masc/keepers/<name>/execution-receipts/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` | `Dated_jsonl.read_recent store 1` for latest receipt | `Keeper_execution_receipt.to_json` | Receipt append also drives reaction ledger/operator broadcast side effects. |
| Keeper metrics | `.masc/keepers/<name>/metrics/YYYY-MM/DD.jsonl` | `Dated_jsonl.append` | dashboard/status detail readers | `Keeper_unified_metrics`, heartbeat snapshots | Store cache is in `Keeper_types_support`. |
| Keeper single-file logs | `.masc/keepers/<name>.memory.jsonl`, `.decisions.jsonl`, `.policy.jsonl`, `.feedback.jsonl`, `.generation_index.jsonl`, trace history files | `Keeper_types_support.append_jsonl_line` or direct append helpers | keeper memory/status/recall/detail readers | Per-keeper modules | Preserve rotation and UTF-8 repair for these paths. |
| Board posts/comments/reactions/sub-boards | `.masc/board_posts.jsonl`, `board_comments.jsonl`, `board_reactions.jsonl`, `board_sub_boards.jsonl` | create-only append for new rows; snapshot rewrite via `save_file_atomic` for mutation flushes | `Board_core` load/list, `Activity_feed` projections | `Board_core` serializers | These are snapshot-like JSONL files after mutation. Do not convert blindly to append-only event logs. |
| Board votes | `.masc/board_votes.jsonl` | append on cast; snapshot rewrite on flush | board vote state and analytics | `Board_votes` | Timestamp preservation is part of the contract. |
| Mention inbox | `.masc/mention_inbox.jsonl` | `Fs_compat.append_jsonl` | `Mention_inbox.load_all_mentions`, `Activity_feed` | `Mention_inbox.mention_record_to_json` | Terminal task mentions are skipped by invariant check before append. |
| Goal verification events | goal verification event path from `Goal_verification.events_path` | `Fs_compat.append_jsonl` | goal verification state/readers | `Goal_verification.emit_event` | Event append is separate from file-locked state update. |
| Trajectory | `.masc/trajectories/<keeper>/<trace_id>.jsonl` | `Fs_compat.append_jsonl` | trajectory affinity/status readers | `Trajectory.entry_to_json`, thinking and summary encoders | Previous local mutex helper was removed in favor of `Fs_compat.append_jsonl`. |
| Runtime/OAS events | date-split OAS/runtime event stores | `Dated_jsonl.append` | dashboard runtime/OAS projections | `Runtime_event_bridge`, `Runtime_trust_persist` | Some append failures recreate `Dated_jsonl` store handles and retry later. |
| Shared audit | `<base_dir>/YYYY-MM/DD.jsonl` | direct `open_out_gen` | `Shared_audit.Store.read_all_entries`, `verify_chain` | `Shared_audit.Envelope` | Hash-chain state means writer migration must preserve append order and `latest_hash`. |

## Contract Invariants To Pin In `task-382`

1. `Fs_compat.append_jsonl` and `Fs_compat.append_file` serialize mixed writes to the same path with one per-path mutex registry.
2. `Dated_jsonl.create` instances for equivalent base dirs share the same mutex, including trailing-slash variants.
3. `Dated_jsonl.append` writes through `Fs_compat.append_jsonl`, keeps `YYYY-MM/DD.jsonl`, and does not poison the base-dir mutex after append failure.
4. `Dated_jsonl.read_recent`, `iter_all`, and `read_range` skip malformed JSON lines instead of failing the whole read.
5. Keeper single-file helpers preserve rotation and UTF-8 repair before delegating to `append_file`.
6. Board post/comment/reaction JSONL files remain snapshot files after mutation flush, while create paths may append.
7. Board vote rows preserve the original cast timestamp across append and rewrite.
8. Shared audit hash-chain append preserves `prev_hash` ordering when moved behind any common adapter.
9. Goal verification event append remains separate from file-locked request-state mutation.
10. Trajectory append stays per `(keeper, trace_id)` path and remains append-only.

## Migration Boundaries

1. First extract tests around the substrate contracts above. Do not move code yet.
2. Introduce a narrow adapter that can express two shapes: single-file append and date-split append. Snapshot rewrite stays outside the adapter.
3. Move date-split stores first because most already use `Dated_jsonl`.
4. Move raw single-file JSONL helpers only after preserving domain-specific preconditions: board snapshot semantics, keeper rotation, UTF-8 repair, and shared-audit hash chaining.
5. Keep dashboard/read-model changes out of the first writer PR. Dashboard should consume the same path contracts until fixture parity is green.

## Known Gaps

- `Shared_audit.Store.append` does not use `Fs_compat.append_jsonl` or `Dated_jsonl`; it has its own hash-chain append path.
- Single-file stores mix raw string JSONL and structured JSON append APIs.
- Store-level cache/failure behavior is duplicated across audit, telemetry, tool usage, tool calls, and keeper receipt stores.
- Some readers silently skip malformed JSON while others report persistence drops. The refactor should preserve current observable reporting per surface before unifying policy names.
- Snapshot JSONL files and append-only event logs share the `.jsonl` extension but have different semantics; treating them as one class would corrupt board behavior.
