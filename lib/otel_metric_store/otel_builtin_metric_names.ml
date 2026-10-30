(** Metric names used by Otel_metric_store built-in registration chunks. *)

include Otel_metric_names


(* A provider cannot carry Keeper-bound runtime MCP tools that require
   request-scoped authorization headers. This counter records each omitted
   tool with the runtime and tool labels. *)

(* #9520: durable coverage-gap records must also have an alertable
   Otel_metric_store surface.  The labels deliberately avoid raw paths and
   error strings; [source], [producer], [dashboard_surface], and
   [stale_reason] are bounded vocabularies owned by telemetry
   producers. *)
let metric_telemetry_coverage_gap = Otel_metric_store_core.declare_counter "masc_telemetry_coverage_gap_total"

(* Phase 0 telemetry fan-in: source discovery/read failures must not collapse
   into an indistinguishable empty dashboard. Labels are bounded by the
   Telemetry_unified.source enum and a small site vocabulary. *)
let metric_telemetry_unified_source_read_failures =
  Otel_metric_store_core.declare_counter "masc_telemetry_unified_source_read_failures_total"
;;

let metric_tool_assignment_telemetry_failures =
  Otel_metric_store_core.declare_counter "masc_tool_assignment_telemetry_failures_total"
;;

(* Phase 0 exception visibility for [Telemetry_observe]: every swallowed
   non-cancel exception logs and increments this bounded-by-callsite counter. *)
let metric_telemetry_observe_failures = Otel_metric_store_core.declare_counter "masc_telemetry_observe_failures_total"

(* #10358 (c1): observability for the silent [Effect.Unhandled] catch-all
   in [lib/workspace.ml] [observe_agent_lifecycle] /
   [observe_task_transition_event].  Those try/with sites swallow the
   exception that fires when the lifecycle hook is dispatched from a
   non-Eio context (test path, bootstrap, certain HTTP handlers).  Before
   this counter, the entire Audit_log + Telemetry pair silently
   disappeared.  Labels: [event_family] (one of [agent_lifecycle] /
   [task_transition]) and [event_kind] (the lifecycle/transition
   variant). [event_kind] for [agent_lifecycle] is one of [join] /
   [rejoin] / [leave] (3 values). [event_kind] for [task_transition]
   uses the 8 [Masc_domain.task_action_to_string] values: [claim] /
   [start] / [done] / [cancel] / [release] / [submit_for_verification]
   / [approve] / [reject]. Both vocabularies are bounded so series
   cardinality is at most 11 (3 + 8). *)
let metric_workspace_telemetry_drop = Otel_metric_store_core.declare_counter "masc_workspace_telemetry_drop_total"

(* Per-caller observation of genuine inner AGENT_CORE timeout exceptions. *)
include Otel_agent_core_metric_names


include Otel_runtime_metric_names

include Otel_transport_metric_names

(* Process-level FD gauges — used in init() and update_fd_gauges. *)
include Otel_core_metric_names

(* masc_pool_* series are emitted solely by [Otel_runtime_observables]
   (computed at exporter tick from [Pool_metrics.current_snapshot]); no
   store cells are declared here, so there is no 0-cell duplicate. *)

include Otel_policy_metric_names

(* P0-2 (2026-05-07): observability for orphan turn loops.
   [_dropped] increments every time [Keeper_registry.update_entry] is
   called against a missing key (caller raced with deregistration).
   [_orphan_threshold_breached] increments once per breach event when
   the per-keeper drop count crosses [orphan_drop_threshold] inside
   [orphan_drop_window_sec]. Together they let operators tell a
   harmless single-update race from a stuck orphan fiber emitting 30+
   drops per turn. See masc 2026-05-07 verifier-loop incident. *)
(* Task-138: Minimum proactive cadence — observability gauges for consecutive
   idle turns and last productive turn timestamps. Labels: keeper. *)
(* PR-M (Leak 9): consecutive [provider_timeout] cycle FAILED strikes
   per keeper. Counter increments on each strike; a strike at
   [outcome=promote] means [Keeper_fiber_crash] was raised so
   [Keeper_supervisor.sweep_and_recover] will respawn the fiber. Without
   the strike→crash promotion these failures repeated silently for
   hours (4h+ zombie keepers observed 2026-04-26). *)
let metric_agent_core_bus_capacity = "masc_agent_core_bus_capacity"

let metric_process_timeout = Otel_metric_store_core.declare_counter "masc_process_timeout_total"
let metric_build_identity_probe_failures = Otel_metric_store_core.declare_counter "masc_build_identity_probe_failures_total"
let metric_distributed_lock_acquire_failed = Otel_metric_store_core.declare_counter "masc_distributed_lock_acquire_failed_total"

(* #10130: boot-time sweep of [save_file_atomic] orphan temp
   files.  Labels: [size_class = empty | with_data].  The
   [with_data] rate is the interesting operator signal — each
   non-zero orphan represents a silent atomic-save failure
   (SIGKILL / ENFILE mid-write) that dropped the payload. *)
let metric_fs_atomic_orphans_cleaned = Otel_metric_store_core.declare_counter "masc_fs_atomic_orphans_cleaned_total"

include Otel_identity_metric_names

(* Centralized metric names prevent typo-induced metric proliferation
   (a single-character typo creates a new invisible metric). *)

(* Centralized metric constants for inline string replacement.
   keeper_hooks_agent_core.ml, keeper_guards.ml, keeper_execution_receipt.ml,
   keeper_tool_execute_runtime.ml, keeper_sandbox_docker.ml,
   keeper_heartbeat_snapshot.ml,
   keeper_unified_metrics.ml. *)
(* AGENT_CORE after-turn response metadata was accepted but omitted its response model
   field. This is provider response-shape telemetry, not keeper policy
   telemetry. *)
let metric_after_turn_response_model_empty = Otel_metric_store_core.declare_counter "masc_after_turn_response_model_empty_total"
let metric_after_turn_response_model_alias = Otel_metric_store_core.declare_counter "masc_after_turn_response_model_alias_total"
let metric_cost_emit_zero_source = Otel_metric_store_core.declare_counter "masc_cost_emit_zero_source_total"
let metric_cost_ledger_status = Otel_metric_store_core.declare_counter "masc_cost_ledger_status_total"
(* metric_keeper_meta_read_failures defined earlier at line 473 (single
   source of truth). Re-binding here would silently shadow without
   changing behavior because the strings are identical, but it makes
   the constant look like it has two declaration sites. *)

(* #20677 incremental-cache health: a boundary past the file size means the
   file shrank/rotated and the reader re-parses from byte 0 (the expensive
   path the cache exists to avoid).  Scanned bytes is the per-cycle read
   cost of the telemetry readers -- the direct measure of the load that
   froze the fleet on 2026-06-09.  Labels: [store] (store directory name). *)
let metric_telemetry_cache_rescans =
  Otel_metric_store_core.declare_counter "masc_telemetry_summary_cache_rescans_total"
let metric_telemetry_scanned_bytes =
  Otel_metric_store_core.declare_counter "masc_telemetry_snapshot_scanned_bytes_total"

(* The dashboard cache patcher drops a lifecycle event it cannot decode and
   bumps this so `rate(...)` sees the encoding regression. It was emitted with
   a bare string at both of its call sites, which is the one thing
   [declare_counter] exists to prevent: an unfired counter that is never
   registered is absent from /metrics rather than 0, so an alert written
   against it cannot be validated until the failure it watches for happens. *)
let metric_keeper_lifecycle_malformed =
  Otel_metric_store_core.declare_counter "masc_keeper_lifecycle_malformed_total"
