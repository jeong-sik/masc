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
val metric_keeper_tool_alias_canonicalizations : string
val metric_keeper_profile_config_conflicts : string
val metric_keeper_oas_timeout_classifications : string
val metric_persistence_read_drops : string
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
val metric_cascade_strategy_decisions : string
val metric_cascade_capacity_events : string
val metric_keeper_invariant_violations : string
val metric_oas_bus_subscriber_stream_depth : string
val metric_oas_bus_publish_block_seconds : string
val metric_oas_bus_publish : string
val metric_runtime_ollama_probe_generate_skips : string

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
val metric_ws_sessions : string

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
