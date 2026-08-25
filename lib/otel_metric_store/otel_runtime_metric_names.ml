(** Runtime schema, inference observation, agent-health, and GC sampler
    metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_mcp_tool_schema_count = "masc_tool_schema_count"
let metric_mcp_tool_schema_component_bytes =
  "masc_tool_schema_component_bytes"
let metric_inference_inflight = "masc_inference_inflight"
let metric_inference_started =
  Otel_metric_store_core.declare_counter "masc_inference_started_total"
let metric_runtime_metrics_eviction =
  Otel_metric_store_core.declare_counter "masc_runtime_metrics_eviction_total"
let metric_runtime_audit_failure =
  Otel_metric_store_core.declare_counter "masc_runtime_audit_failure_total"
let metric_agent_heartbeat_age_seconds = "masc_agent_heartbeat_age_seconds"
let metric_agent_stale_total = Otel_metric_store_core.declare_counter "masc_agent_stale_total"

(* Scheduler runner loop liveness. Incremented once per tick completion by the
   server maintenance fiber. Labels: [outcome] in {ok, error, crash}. *)
let metric_schedule_runner_tick_outcomes =
  Otel_metric_store_core.declare_counter "masc_schedule_runner_tick_outcomes_total"

let metric_gc_minor_words = "masc_gc_minor_words"
let metric_gc_major_words = "masc_gc_major_words"
let metric_gc_heap_words = "masc_gc_heap_words"
let metric_gc_live_words = "masc_gc_live_words"
let metric_gc_compactions = "masc_gc_compactions"
let metric_gc_promoted_words = "masc_gc_promoted_words"
let metric_memory_usage_bytes = "masc_memory_usage_bytes"

(* What the activity-events past-day parse cache is holding. Sizing it from
   outside meant RSS plus [live_words] plus a guessed parse factor over the
   on-disk JSONL -- an estimate good to a factor of two. The record count is
   what a retention change moves, so it is the one to watch. *)
let metric_activity_cache_files = "masc_activity_cache_files"
let metric_activity_cache_records = "masc_activity_cache_records"

(* Eio main-domain scheduler lag: a 1s-interval fiber measures sleep
   overshoot.  Sustained lag means the single domain is blocked by a
   non-yielding syscall or CPU hog -- the shared root cause of the
   2026-06 fleet freezes (#20677, #20684). *)
let metric_eio_loop_lag_seconds = "masc_eio_loop_lag_seconds"

(* Runtime-observable store cells: written by the Otel_runtime_observables
   store writer (30s cadence plus one synchronous bootstrap write,
   masc#29023) and read back by the dashboard runtime-observables endpoint.
   Names lived as locals in otel_runtime_observables.ml while that module
   was the only site; the endpoint made them two-site constants. *)
let metric_console_sink_dropped = "masc_console_sink_dropped_total"
let metric_console_sink_queue_depth = "masc_console_sink_queue_depth"
let metric_transition_audit_queue_depth = "masc_keeper_transition_audit_queue_depth"
let metric_fd_active_operations = "masc_fd_active_operations"
let metric_fd_resource_errors = "masc_fd_resource_errors_total"
let metric_store_bytes = "masc_store_bytes"
let metric_store_files = "masc_store_files"
let metric_bus_subscriber_dropped = "masc_event_bus_subscriber_dropped_total"
let metric_bus_subscriber_depth = "masc_event_bus_subscriber_depth"
let metric_bus_subscribers = "masc_event_bus_subscribers"
(* The masc_pool_* series predate the observables module; the idle and
   inflight gauges keep their historical *_total suffix. *)
let metric_pool_idle = "masc_pool_idle_total"
let metric_pool_inflight = "masc_pool_inflight_total"
let metric_pool_reuse = "masc_pool_reuse_total"
let metric_pool_evict = "masc_pool_evict_total"
let metric_pool_evict_failure = "masc_pool_evict_failure_total"
let metric_pool_create = "masc_pool_create_total"
let metric_runtime_observables_last_write_unixtime =
  "masc_runtime_observables_last_write_unixtime"
