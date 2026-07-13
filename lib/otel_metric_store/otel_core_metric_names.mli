(** Core runtime, LLM, provider, task, goal, and SSE activity metric-name
    constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

val metric_fd_open : string
val metric_fd_limit : string
val metric_mcp_requests : string
val metric_llm_inference_duration : string

(** [masc_llm_prompt_tok_per_sec] - prefill throughput histogram.
    Observed in [Keeper_hooks_oas] after_turn when [response.telemetry.timings]
    is [Some] and [prompt_per_second] is positive. Labels: [model], [provider_kind]. *)
val metric_llm_prompt_tok_per_sec : string

(** [masc_llm_decode_tok_per_sec] - decode throughput histogram.
    Observed alongside {!metric_llm_prompt_tok_per_sec} from the same turn
    when [predicted_per_second] is positive. Silent for providers that do
    not emit timings; inspect [masc_after_turn_telemetry_missing_total] to
    tell absence apart from zero. *)
val metric_llm_decode_tok_per_sec : string

val metric_after_turn_hook : string
val metric_after_turn_telemetry_missing : string
val metric_after_turn_response_content_empty : string
val metric_after_turn_telemetry_zero_latency : string
val metric_tasks : string
val metric_errors : string
val metric_error_events : string
val metric_workspace_route_failures : string
val metric_active_agents : string
val metric_pending_tasks : string

(** RFC-0294 PR-4: gauge of orphaned tasks, labeled by status_class. *)
val metric_orphan_tasks : string

(** Goal attainment percentage by [goal_id]. Companion
    {!metric_goal_attainment_measured} distinguishes real 0% from
    unmeasured goals. *)
val metric_goal_attainment_pct : string

(** Gauge by [goal_id]: [1] when goal attainment percentage is measured,
    [0] when the dashboard projection is currently unmeasured. *)
val metric_goal_attainment_measured : string

val metric_sse_reconnects : string
val metric_sse_idle_evictions : string
val metric_sse_rejects : string
val metric_provider_prefix_cache_creation_tokens : string
val metric_provider_prefix_cache_read_tokens : string
val metric_tool_input_validation : string
val metric_llm_provider_http_status : string
val metric_llm_provider_request_latency : string
val metric_llm_provider_request_latency_clamped : string
val metric_llm_provider_streaming_first_chunk : string
val metric_llm_provider_streaming_inter_chunk : string
val metric_llm_provider_streaming_first_chunk_invalid : string
val metric_llm_provider_streaming_inter_chunk_invalid : string
val metric_llm_provider_capability_drops : string
val metric_llm_provider_cache_hits : string
val metric_llm_provider_cache_misses : string
val metric_llm_provider_requests_started : string
val metric_llm_provider_errors : string
val metric_llm_provider_errors_by_reason : string
val metric_llm_provider_retries : string
val metric_llm_provider_input_tokens : string
val metric_llm_provider_output_tokens : string
val metric_llm_provider_cache_read_tokens : string
val metric_llm_provider_reasoning_tokens : string
val metric_llm_provider_tool_calls : string
val metric_llm_provider_circuit_state : string

(** Section 7.3.2 Zero Silent Failure measurement: aggregate counter for
    every fallback event across the runtime pipeline. Labels: [kind]
    enumerates the fallback class (runtime_empty, capability_drop,
    cli_unsupported, ...); [detail] carries the specific reason within the
    kind (e.g. for runtime_empty: rejection_reason_label). This counter exists
    so the "Zero Silent Failure" dashboard panel has a single numerator across
    all fallback classes. *)
val metric_fallback_triggered : string
