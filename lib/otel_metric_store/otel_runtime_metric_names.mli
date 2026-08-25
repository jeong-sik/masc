(** Runtime schema, inference observation, agent-health, and GC sampler
    metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

(** MCP tool schema budget gauges, set once at boot from [mcp_server_eio.ml]
    via [set_tool_schema_stats]. *)
val metric_mcp_tool_schema_count : string

val metric_mcp_tool_schema_component_bytes : string


val metric_inference_inflight : string
val metric_inference_started : string
val metric_runtime_metrics_eviction : string
val metric_runtime_audit_failure : string

(** {1 Agent health metrics} *)

val metric_agent_heartbeat_age_seconds : string
val metric_agent_stale_total : string

(** Scheduler runner loop completions. Labels: [outcome] in
    [ok | error | crash]. *)
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

val metric_activity_cache_files : string
(** Day files the activity-events parse cache is holding. *)

val metric_activity_cache_records : string
(** Events across those files. This is the number a retention change moves;
    sizing it from outside the process needed RSS, [live_words] and a guessed
    parse factor, which is an estimate rather than an answer. *)

(** Eio main-domain scheduler lag (gauge, seconds): 1s sleep overshoot
    sampled by the bootstrap lag fiber.  Sustained values mean the single
    domain is blocked (2026-06 fleet-freeze root cause class). *)
val metric_eio_loop_lag_seconds : string

(** {1 Runtime-observable store cells}

    Written by the [Otel_runtime_observables] store writer — every 30s and
    once synchronously at bootstrap (masc#29023) — and read back by the
    dashboard runtime-observables endpoint. Every cell lands as a gauge via
    [set_gauge]; the cumulative [_total] readings are
    monotonic-by-construction. *)

(** Console-sink writer health. Unlabeled. *)
val metric_console_sink_dropped : string

val metric_console_sink_queue_depth : string

(** Keeper transition-audit drain queue depth. Unlabeled. *)
val metric_transition_audit_queue_depth : string

(** Active fd-bearing operations. Labels: [kind]. *)
val metric_fd_active_operations : string

(** Cumulative fd/resource failures. Labels: [kind], [error]. *)
val metric_fd_resource_errors : string

(** On-disk telemetry store totals. Labels: [store] (directory name). *)
val metric_store_bytes : string

val metric_store_files : string

(** Event-bus subscriber health. [metric_bus_subscribers] carries only a
    [bus] label; the depth and dropped series add [purpose], [capacity],
    and [overflow]. *)
val metric_bus_subscriber_dropped : string

val metric_bus_subscriber_depth : string
val metric_bus_subscribers : string

(** HTTP connection pool totals. Unlabeled, one series each. *)
val metric_pool_idle : string

val metric_pool_inflight : string
val metric_pool_reuse : string
val metric_pool_evict : string
val metric_pool_evict_failure : string
val metric_pool_create : string

(** Unix time of the last completed store-writer pass. Absent until the
    first write in processes that never start the writer. *)
val metric_runtime_observables_last_write_unixtime : string
