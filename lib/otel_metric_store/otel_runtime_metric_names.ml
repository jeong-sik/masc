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

(* Eio main-domain scheduler lag: a 1s-interval fiber measures sleep
   overshoot.  Sustained lag means the single domain is blocked by a
   non-yielding syscall or CPU hog -- the shared root cause of the
   2026-06 fleet freezes (#20677, #20684). *)
let metric_eio_loop_lag_seconds = "masc_eio_loop_lag_seconds"
