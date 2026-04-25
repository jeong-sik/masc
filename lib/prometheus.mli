(** Prometheus-Compatible Metrics for masc-mcp.

    Lightweight metrics collection with Prometheus text format export.
    Thread-safe via [Stdlib.Mutex] — works across OCaml 5 domains and
    during module initialisation before any Eio scheduler exists.

    @since 0.4.0 *)

(** {1 Types} *)

type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric = {
  name : string;
  help : string;
  metric_type : metric_type;
  mutable value : float;
  labels : label list;
}

(** {1 Metric Registration} *)

val register_counter :
  name:string -> help:string -> ?labels:label list -> unit -> unit

val register_gauge :
  name:string -> help:string -> ?labels:label list -> unit -> unit

val register_histogram :
  name:string -> help:string -> ?labels:label list -> unit -> unit

(** {1 Metric Updates} *)

val inc_counter :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val set_gauge :
  string -> ?labels:label list -> float -> unit

val inc_gauge :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val dec_gauge :
  string -> ?labels:label list -> ?delta:float -> unit -> unit

val observe_histogram :
  string -> ?labels:label list -> float -> unit

(** {1 Metric Queries} *)

val get_metric_value :
  string -> ?labels:label list -> unit -> float option

val metric_value_or_zero :
  string -> ?labels:label list -> unit -> float

val metric_total : string -> float

(** {1 Metric Name Constants}

    Shared SSOT between registration (in [init]) and call-sites in
    keeper/bridge modules. Importing [Prometheus.<constant>] ensures
    the compiler catches typos that would otherwise silently create
    dead series. *)

val metric_keeper_turns : string
val metric_keeper_input_tokens : string
val metric_keeper_output_tokens : string
val metric_keeper_cache_creation_tokens : string
val metric_keeper_cache_read_tokens : string
val metric_keeper_usage_anomalies : string
val metric_keeper_metric_emit_dropped : string
val metric_keeper_context_max_observed : string
(** #9953: bucketed counter for observed [context_max] values.
    Labels: [keeper, model_used, resolved_model_id,
    context_max_bucket].  Bucket vocabulary:
    [64k | 128k | 200k | 256k | 1m | other | zero]. *)
val metric_keeper_turn_starts : string
val metric_keeper_turn_reattempts : string
val metric_keeper_turn_regressions : string
(** #10121: keeper turn livelock observer counters.  Labels:
    [keeper].  Re-attempt = same turn id started again before
    the counter advanced; regression = turn id moved strictly
    backwards (write_meta race symptom — #9733). *)
val metric_keeper_turn_latency_bucket : string
(** #9943: per-keeper turn latency distribution.  Labels:
    [keeper, bucket].  Bucket vocabulary:
    [under_60s | 60-300s | 300-600s | 600-1200s | over_1200s]. *)

(** #10125: supervisor sweep liveness counters.  See {!Prometheus.ml}
    for the rationale.  Counter increments on each Pulse start;
    gauge advances on every successful beat. *)
val metric_keeper_supervisor_sweep_starts : string
val metric_keeper_supervisor_last_sweep_unixtime : string

val metric_tool_join_required_guard : string
(** #9770: count fires of the [join_required] guard in
    [Mcp_server_eio_execute].  Labels:
    [tool, agent_name, reason] with reason
    [room_uninitialized | agent_not_joined]. *)

val metric_keeper_compactions : string
val metric_keeper_compaction_ratio_change : string
val metric_keeper_compaction_saved_tokens : string
val metric_keeper_operator_compact : string
val metric_keeper_operator_clear : string
val metric_keeper_heartbeat_successes : string
val metric_keeper_heartbeat_failures : string
val metric_keeper_tool_call_duration : string
val metric_keeper_write_meta_failures : string
val metric_keeper_lifecycle_dispatch_rejections : string
val metric_keeper_paused_state_persist_errors : string
val metric_keeper_unexpected_tool_partial_tolerance : string
val metric_keeper_require_tool_use_violations : string
(** #10091: labelled [keeper, has_current_task, contract_status]
    so fleet histograms can distinguish the active-task strict
    path from the no-task path covered by #10031. *)
val metric_keeper_tool_alias_canonicalizations : string
val metric_keeper_profile_config_conflicts : string
val metric_keeper_oas_timeout_classifications : string
val metric_keeper_ollama_saturation_skip : string
(** PR-B: counter incremented when [run_keeper_cycle] skips a turn
    because the keeper's resolved cascade is ollama-only and the
    [/api/ps] probe reports zero process_available slots.  Labelled
    by [keeper] and [cascade] so dashboards can attribute starvation
    to specific cascade profiles. *)
val metric_persistence_read_drops : string
val metric_codex_cli_mcp_tool_omission : string
(** #10097: per-tool counter for codex_cli keeper-bound runtime
    MCP omissions.  Paired with a once-per-fingerprint WARN log
    so logs carry structural facts and Prometheus carries
    frequency. *)
val metric_oas_bridge_timeout : string
(** #10094: labelled [caller, timeout_s] so operators can
    distinguish fantasy 60s budgets from intentional 120/180s
    budgets when both fire timeouts in the same session. *)
val metric_oas_sse_relay_retries : string
val metric_oas_sse_relay_drops : string
val metric_oas_sse_relay_queue_depth : string
val metric_mcp_tool_schema_count : string
val metric_mcp_tool_schema_tokens_approx : string

(** {1 Core counters / gauges} *)

val metric_mcp_requests : string
val metric_llm_inference_duration : string

val metric_llm_prompt_tok_per_sec : string
(** [masc_llm_prompt_tok_per_sec] — prefill throughput histogram.
    Observed in [Keeper_hooks_oas] after_turn when [response.telemetry.timings]
    is [Some] and [prompt_per_second] is positive. Labels: [model], [provider_kind]. *)

val metric_llm_decode_tok_per_sec : string
(** [masc_llm_decode_tok_per_sec] — decode throughput histogram.
    Observed alongside {!metric_llm_prompt_tok_per_sec} from the same turn
    when [predicted_per_second] is positive. Silent for providers that do
    not emit timings; inspect [masc_after_turn_telemetry_missing_total] to
    tell absence apart from zero. *)

val metric_after_turn_hook : string
val metric_after_turn_telemetry_missing : string
val metric_after_turn_telemetry_zero_latency : string
val metric_tasks : string
val metric_errors : string
val metric_error_events : string
val metric_active_agents : string
val metric_pending_tasks : string
val metric_uptime_seconds : string
val metric_sse_connections_active : string
val metric_sse_reconnects : string
val metric_sse_idle_evictions : string
val metric_sse_capacity_evictions : string
val metric_sse_write_failures : string
val metric_sse_rejects : string
val metric_provider_prefix_cache_creation_tokens : string
val metric_provider_prefix_cache_read_tokens : string
val metric_tool_call : string
val metric_tool_call_duration : string
val metric_llm_provider_http_status : string
val metric_llm_provider_request_latency : string
val metric_board_truncated_posts : string
val metric_anti_rationalization_fallback : string
val metric_anti_rationalization_excuse_pattern : string
(** #10113: per-pattern + per-decision counter for the gate 2
    excuse substring detector.  Decision label is
    [advisory_to_llm | terminal_reject | advisory_safety_net_reject]. *)
val metric_cascade_strategy_decisions : string
val metric_cascade_capacity_events : string
val metric_keeper_invariant_violations : string
val metric_keeper_dead_total : string
(** Total keeper transitions to [Dead] phase after restart-budget exhaustion.
    Labeled by [keeper] and [reason]. Operators should alert on any rate >0:
    by construction Dead means the supervisor gave up and no further
    restart will be attempted. *)
val metric_keeper_near_exhaustion_total : string
(** Total times a keeper restart attempt landed at
    [restart_count = max_restarts - 1], i.e. one attempt away from Dead.
    Soft pre-warning; labeled by [keeper]. *)
val metric_oas_bus_subscriber_stream_depth : string
val metric_oas_bus_publish_block_seconds : string
val metric_oas_bus_publish : string
val metric_runtime_ollama_probe_generate_skips : string

(** #10130: boot-time sweep of save_file_atomic orphan temp files.
    Labels: [size_class = empty | with_data]. *)
val metric_fs_atomic_orphans_cleaned : string

(** #9786: Auth rejects where bearer token owner does not match the
    requested agent_name.  Labels: [expected_agent, actual_agent].
    Dashboards alert on rate advancing after a server restart as a
    signal of shared credential state (connection pool / fork). *)
val metric_auth_bearer_token_mismatch : string


(** {1 Transport metrics} *)

val metric_sse_sessions : string
val metric_sse_broadcast_duration : string
val metric_sse_broadcast_events : string
val metric_sse_stream_queue_depth : string
val metric_sse_queue_depth_avg : string
val metric_sse_queue_depth_max : string
val metric_sse_external_subscribers : string
val metric_grpc_active_streams : string
val metric_grpc_heartbeat_latency : string
val metric_grpc_subscribers : string
val metric_grpc_events_delivered : string
val metric_grpc_events_dropped : string
val metric_ws_sessions : string
val metric_ws_parse_cache_hits : string
val metric_ws_parse_cache_misses : string
val metric_ws_bytes_cache_hits : string
val metric_ws_bytes_cache_misses : string
val metric_ws_client_buffered_bytes : string
val metric_ws_client_acks : string
val metric_ws_throttled_deliveries : string
val metric_ws_slice_fanout_skipped : string

(** {1 Admission queue metrics} *)

val metric_inference_queue_depth : string
val metric_inference_queue_inflight : string
val metric_inference_queue_acquired : string
val metric_inference_queue_wait : string
val metric_inference_queue_cancelled : string
val metric_inference_queue_max_concurrent : string

(** {1 Agent health metrics} *)

val metric_agent_heartbeat_age_seconds : string
val metric_agent_stale_total : string

(** {1 Process monitoring} *)

val approximate_open_fd_count : unit -> int

val fd_warn_threshold : int

val set_tool_schema_stats : count:int -> approx_tokens:int -> unit

(** {1 Prometheus Export} *)

val type_to_string : metric_type -> string

val labels_to_string : label list -> string

val to_prometheus_text : unit -> string

(** {1 Convenience Functions} *)

val record_request : unit -> unit
val record_task_completed : unit -> unit
val record_task_failed : unit -> unit
val record_error : ?error_type:string -> unit -> unit
val set_active_agents : int -> unit
val set_pending_tasks : int -> unit
val reconcile_active_agents_gauge : string -> unit
val update_uptime : unit -> unit

(** {1 Initialisation}

    Called automatically at module load via [let () = init ()].
    Idempotent — safe to call again. *)
val init : unit -> unit
