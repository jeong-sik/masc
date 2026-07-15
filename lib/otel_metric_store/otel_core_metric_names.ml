(** Core runtime, LLM, provider, task, keeper, and SSE activity metric-name
    constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_fd_open = "masc_fd_open"
let metric_fd_limit = "masc_fd_limit"
let metric_mcp_requests = Otel_metric_store_core.declare_counter "masc_requests_total"
let metric_llm_inference_duration = "masc_llm_inference_duration_seconds"
let metric_llm_prompt_tok_per_sec = "masc_llm_prompt_tok_per_sec"
let metric_llm_decode_tok_per_sec = "masc_llm_decode_tok_per_sec"
let metric_after_turn_hook = Otel_metric_store_core.declare_counter "masc_after_turn_hook_total"
let metric_after_turn_telemetry_missing = Otel_metric_store_core.declare_counter "masc_after_turn_telemetry_missing_total"
let metric_after_turn_response_content_empty = Otel_metric_store_core.declare_counter "masc_after_turn_response_content_empty_total"
let metric_after_turn_telemetry_zero_latency = Otel_metric_store_core.declare_counter "masc_after_turn_telemetry_zero_latency_total"
let metric_tasks = Otel_metric_store_core.declare_counter "masc_tasks_total"
let metric_errors = Otel_metric_store_core.declare_counter "masc_errors_total"
let metric_error_events = Otel_metric_store_core.declare_counter "masc_error_events_total"
let metric_workspace_route_failures = Otel_metric_store_core.declare_counter "masc_workspace_route_failures_total"
let metric_active_agents = "masc_active_agents"
let metric_pending_tasks = "masc_pending_tasks"

(* RFC-0294 PR-4: gauge of orphaned tasks (claimed/in_progress/awaiting_verification
   whose assignee is no longer active), labeled by status_class. A gauge (current
   count), not a counter — no [_total] suffix, matching masc_pending_tasks. *)
let metric_orphan_tasks = "masc_orphan_tasks"
let metric_sse_reconnects = Otel_metric_store_core.declare_counter "masc_sse_reconnects_total"
let metric_sse_idle_evictions = Otel_metric_store_core.declare_counter "masc_sse_idle_evictions_total"
let metric_sse_rejects = Otel_metric_store_core.declare_counter "masc_sse_rejects_total"

let metric_provider_prefix_cache_creation_tokens =
  Otel_metric_store_core.declare_counter "masc_provider_prefix_cache_creation_tokens_total"
;;

let metric_provider_prefix_cache_read_tokens =
  Otel_metric_store_core.declare_counter "masc_provider_prefix_cache_read_tokens_total"
;;
let metric_tool_input_validation = Otel_metric_store_core.declare_counter "masc_tool_input_validation_total"
let metric_llm_provider_http_status = Otel_metric_store_core.declare_counter "masc_llm_provider_http_status_total"
let metric_llm_provider_request_latency = "masc_llm_provider_request_latency_seconds"
let metric_llm_provider_request_latency_clamped = Otel_metric_store_core.declare_counter "masc_llm_provider_request_latency_clamped_total"
let metric_llm_provider_streaming_first_chunk = "masc_llm_provider_streaming_first_chunk_seconds"
let metric_llm_provider_streaming_inter_chunk = "masc_llm_provider_streaming_inter_chunk_seconds"
let metric_llm_provider_streaming_first_chunk_invalid = Otel_metric_store_core.declare_counter "masc_llm_provider_streaming_first_chunk_invalid_total"
let metric_llm_provider_streaming_inter_chunk_invalid = Otel_metric_store_core.declare_counter "masc_llm_provider_streaming_inter_chunk_invalid_total"
let metric_llm_provider_capability_drops = Otel_metric_store_core.declare_counter "masc_llm_provider_capability_drops_total"
let metric_llm_provider_cache_hits = Otel_metric_store_core.declare_counter "masc_llm_provider_cache_hits_total"
let metric_llm_provider_cache_misses = Otel_metric_store_core.declare_counter "masc_llm_provider_cache_misses_total"
let metric_llm_provider_requests_started = Otel_metric_store_core.declare_counter "masc_llm_provider_requests_started_total"
let metric_llm_provider_errors = Otel_metric_store_core.declare_counter "masc_llm_provider_errors_total"
let metric_llm_provider_errors_by_reason = Otel_metric_store_core.declare_counter "masc_llm_provider_errors_by_reason_total"
let metric_llm_provider_retries = Otel_metric_store_core.declare_counter "masc_llm_provider_retries_total"
let metric_llm_provider_input_tokens = Otel_metric_store_core.declare_counter "masc_llm_provider_input_tokens_total"
let metric_llm_provider_output_tokens = Otel_metric_store_core.declare_counter "masc_llm_provider_output_tokens_total"
let metric_llm_provider_cache_read_tokens = Otel_metric_store_core.declare_counter "masc_llm_provider_cache_read_tokens_total"
let metric_llm_provider_reasoning_tokens = Otel_metric_store_core.declare_counter "masc_llm_provider_reasoning_tokens_total"
let metric_llm_provider_tool_calls = Otel_metric_store_core.declare_counter "masc_llm_provider_tool_calls_total"
let metric_llm_provider_circuit_state = "masc_llm_provider_circuit_state"
let metric_fallback_triggered = Otel_metric_store_core.declare_counter "masc_fallback_triggered_total"
