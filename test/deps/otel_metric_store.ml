type label = string * string

type metric_type =
  | Counter
  | Gauge
  | Histogram

type metric =
  { name : string
  ; help : string
  ; metric_type : metric_type
  ; mutable value : float
  ; labels : label list
  }

let store : metric list ref = ref []

let metric_key name labels = name, List.sort compare labels

let find_metric name labels =
  let key = metric_key name labels in
  List.find_opt (fun metric -> metric_key metric.name metric.labels = key) !store
;;

let ensure_metric ?(help = "") ?(metric_type = Counter) name labels =
  match find_metric name labels with
  | Some metric -> metric
  | None ->
    let metric = { name; help; metric_type; value = 0.0; labels } in
    store := metric :: !store;
    metric
;;

let register_counter ~name ~help ?(labels = []) () =
  ignore (ensure_metric ~help ~metric_type:Counter name labels)
;;

let register_gauge ~name ~help ?(labels = []) () =
  ignore (ensure_metric ~help ~metric_type:Gauge name labels)
;;

let register_histogram ~name ~help ?(labels = []) () =
  ignore (ensure_metric ~help ~metric_type:Histogram name labels)
;;

let add ~name ~help ?(labels = []) metric_type =
  ignore (ensure_metric ~help ~metric_type name labels)
;;

let inc_counter name ?(labels = []) ?(delta = 1.0) () =
  let metric = ensure_metric ~metric_type:Counter name labels in
  metric.value <- metric.value +. delta
;;

let set_gauge name ?(labels = []) value =
  let metric = ensure_metric ~metric_type:Gauge name labels in
  metric.value <- value
;;

let inc_gauge name ?(labels = []) ?(delta = 1.0) () =
  let metric = ensure_metric ~metric_type:Gauge name labels in
  metric.value <- metric.value +. delta
;;

let dec_gauge name ?(labels = []) ?(delta = 1.0) () =
  inc_gauge name ~labels ~delta:(-.delta) ()
;;

let observe_histogram name ?(labels = []) value =
  let metric = ensure_metric ~metric_type:Histogram name labels in
  metric.value <- metric.value +. value;
  let count = ensure_metric ~metric_type:Counter (name ^ "_count") labels in
  count.value <- count.value +. 1.0
;;

let get_metric_value name ?(labels = []) () =
  find_metric name labels |> Option.map (fun metric -> metric.value)
;;

let metric_value_or_zero name ?(labels = []) () =
  get_metric_value name ~labels () |> Option.value ~default:0.0
;;

let metric_total name =
  !store
  |> List.fold_left
       (fun acc metric -> if String.equal metric.name name then acc +. metric.value else acc)
       0.0
;;

let snapshot () = List.map (fun metric -> { metric with labels = metric.labels }) !store
let update_pool_metrics_gauges () = ()

let metric_auth_credential_ambiguous_lookup = "masc_auth_credential_ambiguous_lookup_total"
let metric_auth_credential_hash_collision = Otel_identity_metric_names.metric_auth_credential_hash_collision
let metric_auth_strict_unknown_tool_denials = "masc_auth_strict_unknown_tool_denials_total"
let metric_after_turn_response_model_empty = "masc_after_turn_response_model_empty_total"
let metric_after_turn_response_model_alias = "masc_after_turn_response_model_alias_total"
let metric_anti_rationalization_excuse_pattern = "masc_anti_rationalization_excuse_pattern_total"
let metric_build_identity_probe_failures = "masc_build_identity_probe_failures_total"
let metric_config_unknown_keys_ignored = "masc_config_unknown_keys_ignored_total"
let metric_dashboard_execution_render_phase_sec = "masc_dashboard_execution_render_phase_seconds"
let metric_dashboard_metric_all_zeros = "masc_dashboard_metric_all_zeros"
let metric_dashboard_snapshot_latency_seconds_bucket = "masc_dashboard_snapshot_latency_seconds_bucket"
let metric_discovery_history_failures = "masc_discovery_history_failures_total"
let metric_distributed_lock_acquire_failed = "masc_distributed_lock_acquire_failed_total"
let metric_fsm_guard_violation = "masc_fsm_guard_violation_total"
let metric_gc_compactions = "masc_gc_compactions"
let metric_gc_heap_words = "masc_gc_heap_words"
let metric_gc_live_words = "masc_gc_live_words"
let metric_gc_major_words = "masc_gc_major_words"
let metric_gc_minor_words = "masc_gc_minor_words"
let metric_gc_promoted_words = "masc_gc_promoted_words"
let metric_governance_judge_unparseable = "masc_governance_judge_unparseable_total"
let metric_governance_strict_json_parse_reject = "masc_governance_strict_json_parse_reject_total"
let metric_http_accept_errors = "masc_http_accept_errors_total"
let metric_http_accepts = "masc_http_accepts_total"
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
let metric_llm_provider_request_latency = "masc_llm_provider_request_latency_seconds"
let metric_llm_provider_request_latency_clamped = "masc_llm_provider_request_latency_clamped_total"
let metric_llm_provider_streaming_first_chunk = "masc_llm_provider_streaming_first_chunk_seconds"
let metric_llm_provider_streaming_inter_chunk = "masc_llm_provider_streaming_inter_chunk_seconds"
let metric_llm_provider_streaming_first_chunk_invalid = "masc_llm_provider_streaming_first_chunk_invalid_total"
let metric_llm_provider_streaming_inter_chunk_invalid = "masc_llm_provider_streaming_inter_chunk_invalid_total"
let metric_memory_usage_bytes = "masc_memory_usage_bytes"
let metric_oas_sse_relay_drops = "masc_oas_sse_relay_drops_total"
let metric_oas_sse_relay_queue_depth = "masc_oas_sse_relay_queue_depth"
let metric_oas_sse_relay_retries = "masc_oas_sse_relay_retries_total"
let metric_persistence_read_drops = "masc_persistence_read_drops_total"
let metric_persistence_utf8_repair = "masc_persistence_utf8_repair_total"
let metric_process_timeout = "masc_process_timeout_total"
let metric_runtime_ollama_probe_generate_skips = "masc_runtime_ollama_probe_generate_skips_total"
let metric_silent_dashboard_actor_fallback = "masc_silent_dashboard_actor_fallback_total"
let metric_sse_broadcast_duration = "masc_sse_broadcast_duration_seconds"
let metric_telemetry_coverage_gap = "masc_telemetry_coverage_gap_total"
let metric_telemetry_observe_failures = "masc_telemetry_observe_failures_total"
let metric_telemetry_unified_source_read_failures = "masc_telemetry_unified_source_read_failures_total"
let metric_tool_assignment_telemetry_failures = "masc_tool_assignment_telemetry_failures_total"
let metric_tool_bind_required_guard = "masc_tool_bind_required_guard_total"
let metric_tool_input_validation = "masc_tool_input_validation_total"
let metric_workspace_route_failures = "masc_workspace_route_failures_total"
let metric_workspace_telemetry_drop = "masc_workspace_telemetry_drop_total"
let metric_write_meta_cas_retry_total = "masc_write_meta_cas_retry_total"
let metric_ws_bytes_cache_hits = "masc_ws_bytes_cache_hits_total"
let metric_ws_bytes_cache_misses = "masc_ws_bytes_cache_misses_total"
let metric_ws_client_acks = "masc_ws_client_acks_total"
let metric_ws_client_buffered_bytes = "masc_ws_client_buffered_bytes"
let metric_ws_dashboard_hello_latency_seconds = "masc_ws_dashboard_hello_latency_seconds"
let metric_ws_parse_cache_hits = "masc_ws_parse_cache_hits_total"
let metric_ws_parse_cache_misses = "masc_ws_parse_cache_misses_total"
let metric_ws_slice_fanout_skipped = "masc_ws_slice_fanout_skipped_total"
let metric_ws_throttled_deliveries = "masc_ws_throttled_deliveries_total"
