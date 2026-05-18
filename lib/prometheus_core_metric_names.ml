(** Core runtime, LLM, provider, task, goal, and SSE activity metric-name
    constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_fd_open = "masc_fd_open"
let metric_fd_limit = "masc_fd_limit"
let metric_fd_in_flight = "masc_fd_in_flight"
let metric_fd_pressure_active = "masc_fd_pressure_active"
let metric_mcp_requests = "masc_mcp_requests_total"
let metric_llm_inference_duration = "masc_llm_inference_duration_seconds"
let metric_llm_prompt_tok_per_sec = "masc_llm_prompt_tok_per_sec"
let metric_llm_decode_tok_per_sec = "masc_llm_decode_tok_per_sec"
let metric_after_turn_hook = "masc_after_turn_hook_total"
let metric_after_turn_telemetry_missing = "masc_after_turn_telemetry_missing_total"
let metric_after_turn_response_content_empty = "masc_after_turn_response_content_empty_total"
let metric_after_turn_telemetry_zero_latency = "masc_after_turn_telemetry_zero_latency_total"
let metric_tasks = "masc_tasks_total"
let metric_errors = "masc_errors_total"
let metric_error_events = "masc_error_events_total"
let metric_workspace_route_failures = "masc_workspace_route_failures_total"
let metric_active_agents = "masc_active_agents"
let metric_pending_tasks = "masc_pending_tasks"
let metric_uptime_seconds = "masc_uptime_seconds"
let metric_goal_attainment_pct = "masc_goal_attainment_pct"
let metric_goal_attainment_measured = "masc_goal_attainment_measured"
let metric_sse_connections_active = "masc_sse_connections_active"
let metric_sse_reconnects = "masc_sse_reconnects_total"
let metric_sse_idle_evictions = "masc_sse_idle_evictions_total"
let metric_sse_capacity_evictions = "masc_sse_capacity_evictions_total"
let metric_sse_write_failures = "masc_sse_write_failures_total"
let metric_sse_rejects = "masc_sse_rejects_total"

let metric_provider_prefix_cache_creation_tokens =
  "masc_provider_prefix_cache_creation_tokens_total"
;;

let metric_provider_prefix_cache_read_tokens =
  "masc_provider_prefix_cache_read_tokens_total"
;;

let metric_tool_call = "masc_tool_call_total"
let metric_tool_call_duration = "masc_tool_call_duration_seconds"
let metric_tool_input_validation = "masc_tool_input_validation_total"
let metric_llm_provider_http_status = "masc_llm_provider_http_status_total"
let metric_llm_provider_request_latency = "masc_llm_provider_request_latency_seconds"
let metric_llm_provider_request_latency_clamped = "masc_llm_provider_request_latency_clamped_total"
let metric_llm_provider_streaming_first_chunk = "masc_llm_provider_streaming_first_chunk_seconds"
let metric_llm_provider_streaming_inter_chunk = "masc_llm_provider_streaming_inter_chunk_seconds"
let metric_llm_provider_streaming_first_chunk_invalid = "masc_llm_provider_streaming_first_chunk_invalid_total"
let metric_llm_provider_streaming_inter_chunk_invalid = "masc_llm_provider_streaming_inter_chunk_invalid_total"
let metric_llm_provider_capability_drops = "masc_llm_provider_capability_drops_total"
let metric_llm_provider_cache_hits = "masc_llm_provider_cache_hits_total"
let metric_llm_provider_cache_misses = "masc_llm_provider_cache_misses_total"
let metric_llm_provider_requests_started = "masc_llm_provider_requests_started_total"
let metric_llm_provider_errors = "masc_llm_provider_errors_total"
let metric_llm_provider_errors_by_reason = "masc_llm_provider_errors_by_reason_total"
let metric_llm_provider_retries = "masc_llm_provider_retries_total"
let metric_llm_provider_input_tokens = "masc_llm_provider_input_tokens_total"
let metric_llm_provider_output_tokens = "masc_llm_provider_output_tokens_total"
let metric_llm_provider_tool_calls = "masc_llm_provider_tool_calls_total"
let metric_llm_provider_circuit_state = "masc_llm_provider_circuit_state"
let metric_fallback_triggered = "masc_fallback_triggered_total"
