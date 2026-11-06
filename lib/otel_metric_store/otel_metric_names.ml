(** Otel_metric_store metric-name string constants — extracted from [Otel_metric_store]
    to keep the parent file under the Godfile size cap. See
    [Otel_metric_store.ml] § "Metric Name Constants" for the convention.

    This module is [include]d in [Otel_metric_store] so callers reach every
    binding via [Otel_metric_store.metric_X] unchanged. *)

(** {1 Metric Name Constants}

    Exported so registration here and [inc_counter] / [set_gauge]
    call-sites in the keeper modules share a single source of truth.
    Without this, a typo on either side produces a dead series with
    no build error (the counter silently drifts to a new key).

    Convention: constant name drops the Otel_metric_store convention suffix
    ([_total] for counters), full metric name lives on the right-hand
    side. Consumers import [Otel_metric_store.<constant>] so the compiler
    catches typos. *)

(* #10569: board persist mutex acquire / held latency.  Recorded by
   [Board_core.with_persist_lock] so operators can distinguish
   queueing from syscall stall when masc_board_post / comment / vote
   tool calls hit the 60s default tool timeout. *)
let metric_board_persist_lock_acquire_sec = "masc_board_persist_lock_acquire_sec"
let metric_board_persist_lock_held_sec = "masc_board_persist_lock_held_sec"

(* Backend filesystem mutex contention diagnostic.  Recorded by
   [Backend.FileSystem.with_observed_mutex] via
   [Backend.FileSystem.set_mutex_observers] (installed once from the
   main library at startup).  Scoped to writer paths
   (set / delete / set_if_not_exists). Read paths are not measured by
   these histograms. Labels: [op]. *)
let metric_backend_mutex_acquire_sec = "masc_backend_mutex_acquire_sec"
let metric_backend_mutex_held_sec = "masc_backend_mutex_held_sec"

(* Tool metric rows that SQLite could not persist. No labels (single source). *)
let metric_tool_metrics_persist_dropped =
  Otel_metric_store_core.declare_counter "masc_tool_metrics_persist_dropped_total"

let metric_keeper_waiting_count = "masc_keeper_waiting_count"
let metric_keeper_waiting_age_seconds = "masc_keeper_waiting_age_seconds"
let metric_keeper_waiting_keeper_count = "masc_keeper_waiting_keeper_count"

(* Schedule unsupported payload counter. Labels:
   - [phase] in {creation, dispatch}.
   Raw payload kinds are intentionally not labels; they remain in typed
   errors/projections to avoid unbounded metric cardinality. *)
let metric_schedule_payload_unsupported_total =
  Otel_metric_store_core.declare_counter "masc_schedule_payload_unsupported_total"

let metric_tool_bind_required_guard =
  Otel_metric_store_core.declare_counter "masc_tool_bind_required_guard_total"

(* keeper_tool_call_log async append queue overflow.
   Counts full-I/O tool-call records dropped because the bounded
   best-effort queue is full. No labels (single source). *)
let metric_keeper_tool_call_log_queue_dropped =
  Otel_metric_store_core.declare_counter "masc_keeper_tool_call_log_queue_dropped_total"

(* keeper_tool_surface_ops.cached_json_by_key publication conflicts.
   A competing reader's publication reuses the completed result; only an
   explicit invalidation generation forces another computation. This
   counter counts both kinds of conflict, not just recomputations.
   No labels: the helper is
   currently used only for keeper_list_cache; add a cache label if a
   second caller is introduced. *)
let metric_tool_keeper_cache_cas_conflicts =
  Otel_metric_store_core.declare_counter "masc_tool_keeper_cache_cas_conflicts_total"

(* File_lock_eio lock-table CAS retries (single shared atomic).
   Bumped from [atomic_update] / [atomic_update_with_result] retry
   branches via [on_cas_retry_fn] callback wired in workspace.ml — the
   masc_process sub-library cannot depend on Otel_metric_store directly. *)
let metric_file_lock_table_cas_retries =
  Otel_metric_store_core.declare_counter "masc_file_lock_table_cas_retries_total"

(* keeper_tool_surface.cache_ttl_seconds env-var parse fallback observability.
   Operator-supplied env var (e.g. MASC_KEEPER_LIST_CACHE_TTL_S) is
   present but the value cannot be parsed as a non-negative float; the
   helper silently coalesces to the per-caller default. Without this
   counter the operator never learns the env var has no effect ("set
   to 5s but cache still 2s" symptom). Closed-vocabulary labels:
     env_var: the env var name (bounded to the handful of callers)
     reason:  invalid_float | negative_or_nan *)
let metric_tool_keeper_cache_ttl_parse_failures =
  Otel_metric_store_core.declare_counter "masc_tool_keeper_cache_ttl_parse_failures_total"

let metric_cache_desync_cleared = Otel_metric_store_core.declare_counter "masc_cache_desync_cleared_total"
let metric_persistence_read_drops = Otel_metric_store_core.declare_counter "masc_persistence_read_drops_total"
let metric_persistence_utf8_repair = Otel_metric_store_core.declare_counter "masc_persistence_utf8_repair_total"
