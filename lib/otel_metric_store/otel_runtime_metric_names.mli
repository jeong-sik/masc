(** Runtime schema, admission queue, agent-health, and GC sampler
    metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

(** MCP tool schema budget gauges, set once at boot from [mcp_server_eio.ml]
    via [set_tool_schema_stats]. *)
val metric_mcp_tool_schema_count : string

val metric_mcp_tool_schema_tokens_approx : string


val metric_inference_queue_inflight : string
val metric_inference_queue_acquired : string
val metric_inference_queue_wait : string

(** Total admission requests rejected before execution. Labels:
    [surface=with_permit|try_with_permit] and
    [reason=host_resource_saturated]. *)
val metric_inference_queue_rejected : string

(** Maximum configured concurrent inference permits. *)
val metric_inference_queue_max_concurrent : string

(** {1 Agent health metrics} *)

val metric_agent_heartbeat_age_seconds : string
val metric_agent_stale_total : string

(** Scheduler runner loop completions. Labels: [outcome] in
    {[ok | error | crash]}. *)
val metric_schedule_runner_tick_outcomes : string

(** {1 OCaml GC sampler gauges}

    Populated by {!module:Gc_sampler} once per sampling interval from
    [Gc.quick_stat]. The cumulative word counters are exposed as [Gauge]
    because they are read from the OCaml runtime as point-in-time snapshots;
    backend [rate] queries still work on monotonic-by-construction gauges. *)

(** Cumulative words allocated in the minor heap since program start. *)
val metric_gc_minor_words : string

(** Cumulative words allocated in the major heap since program start. *)
val metric_gc_major_words : string

(** Current size of the major heap, in words. *)
val metric_gc_heap_words : string

(** Number of live words in the major heap at last sample. *)
val metric_gc_live_words : string

(** Number of major-heap compactions since program start. *)
val metric_gc_compactions : string

(** Cumulative words promoted from minor to major heap since program start. *)
val metric_gc_promoted_words : string

(** Approximate live OCaml heap memory usage in bytes, derived from
    [Gc.quick_stat.live_words] and [Sys.word_size]. *)
val metric_memory_usage_bytes : string

(** Eio main-domain scheduler lag (gauge, seconds): 1s sleep overshoot
    sampled by the bootstrap lag fiber.  Sustained values mean the single
    domain is blocked (2026-06 fleet-freeze root cause class). *)
val metric_eio_loop_lag_seconds : string
