(** Otel_metric_store facade.

    Keeps the historical metric-name and in-process counter API as the local
    accumulator, and exposes the same snapshot as an OpenTelemetry metric source
    during server bootstrap. *)

include Otel_metric_store_core
include Otel_metric_names
include Otel_builtin_metric_names
include Otel_oas_metric_names
include Otel_runtime_metric_names
include Otel_core_metric_names
include Otel_policy_metric_names
include Otel_identity_metric_names
include Otel_transport_metric_names

let metric_keeper_waiting_count = Otel_metric_names.metric_keeper_waiting_count

let metric_keeper_waiting_age_seconds =
  Otel_metric_names.metric_keeper_waiting_age_seconds
;;

let metric_keeper_waiting_keeper_count =
  Otel_metric_names.metric_keeper_waiting_keeper_count
;;

let metric_schedule_approval_blocked_count =
  Otel_metric_names.metric_schedule_approval_blocked_count
;;

let metric_schedule_approval_wait_seconds =
  Otel_metric_names.metric_schedule_approval_wait_seconds
;;

let metric_schedule_payload_unsupported_total =
  Otel_metric_names.metric_schedule_payload_unsupported_total
;;

let otel_kind_of_metric_type = function
  | Counter -> Otel_metrics.Counter
  | Gauge -> Otel_metrics.Gauge
  | Histogram -> Otel_metrics.Histogram
;;

let otel_samples () =
  snapshot ()
  |> List.map (fun (metric : Otel_metric_store_core.metric) ->
    { Otel_metrics.name = metric.name
    ; value = metric.value
    ; labels = metric.labels
    ; kind = otel_kind_of_metric_type metric.metric_type
    })
;;

let otel_source_registered = Atomic.make false

let register_histogram_buckets = Otel_metric_store_core.register_histogram_buckets

let register_otel_source_once () =
  if not (Atomic.exchange otel_source_registered true) then
    Otel_metrics.register_source otel_samples
;;

let otel_source_registered_for_test () = Atomic.get otel_source_registered
let otel_samples_for_test () = otel_samples ()

let set_tool_schema_stats ~count ~approx_tokens =
  set_gauge metric_mcp_tool_schema_count (Float.of_int count);
  set_gauge metric_mcp_tool_schema_tokens_approx (Float.of_int approx_tokens)
;;

let record_request () = inc_counter metric_mcp_requests ()

let record_task_completed () =
  inc_counter metric_tasks ~labels:[ "status", "completed" ] ()
;;

let record_task_failed () =
  inc_counter metric_tasks ~labels:[ "status", "failed" ] ()
;;

let record_error ?(error_type = "unknown") () =
  inc_counter metric_errors ~labels:[ "type", error_type ] ()
;;

let set_active_agents count =
  set_gauge metric_active_agents (Float.of_int count)
;;

let set_pending_tasks count =
  set_gauge metric_pending_tasks (Float.of_int count)
;;

let reconcile_active_agents_gauge (_masc_dir : string) = ()

let update_uptime () = ()

let init () =
  (* Register histogram bucket upper bounds for histograms that use
     [observe_histogram] without manual [_bucket] counter management.
     This gives dashboards usable le-bucket series for histogram_quantile.
     Metrics that already manage their own _bucket counters
     (e.g. dashboard_snapshot_latency, tool_call_duration) are NOT listed here
     to avoid double counting. *)
  let reg = register_histogram_buckets in
  reg "masc_llm_inference_duration_seconds"
    [ 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0; 120.0; 300.0; 600.0 ];
  reg "masc_backend_mutex_acquire_sec"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0 ];
  reg "masc_backend_mutex_held_sec"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0; 60.0 ];
  reg "masc_dashboard_execution_render_phase_seconds"
    [ 0.001; 0.005; 0.01; 0.025; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0 ];
  reg "masc_keeper_turn_phase_duration_seconds"
    [ 0.1; 0.5; 1.0; 5.0; 10.0; 30.0; 60.0; 120.0; 300.0; 600.0 ];
  reg "masc_workspace_broadcast_duration_seconds"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0 ];
  reg "masc_file_lock_acquire_seconds"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0 ];
  reg "masc_cache_stuck_elapsed_seconds"
    [ 0.1; 0.5; 1.0; 5.0; 10.0; 30.0; 60.0; 300.0; 600.0 ];
  reg "masc_governance_judge_compute_duration_seconds"
    [ 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0; 30.0; 60.0 ];
  reg "gen_ai.client.token.usage"
    [ 1.0; 10.0; 100.0; 1000.0; 10000.0; 100000.0; 1000000.0 ];
  reg "mcp.client.operation.duration"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0; 30.0; 60.0 ];
  reg "mcp.server.operation.duration"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0; 30.0; 60.0 ];
  reg "mcp.client.session.duration"
    [ 0.1; 0.5; 1.0; 5.0; 10.0; 60.0; 300.0; 600.0 ];
  reg "mcp.server.session.duration"
    [ 0.1; 0.5; 1.0; 5.0; 10.0; 60.0; 300.0; 600.0 ];
  reg "gen_ai.client.operation.duration"
    [ 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0 ];
  reg "gen_ai.client.operation.time_to_first_chunk"
    [ 0.01; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0 ];
  reg "gen_ai.client.operation.time_per_output_chunk"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0 ];
  reg "masc_llm_provider_request_latency_seconds"
    [ 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0 ];
  reg "masc_llm_provider_streaming_first_chunk_seconds"
    [ 0.01; 0.05; 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0 ];
  reg "masc_inference_queue_wait_seconds"
    [ 0.1; 0.25; 0.5; 1.0; 2.5; 5.0; 10.0; 30.0; 60.0 ];
  reg "masc_sse_broadcast_duration_seconds"
    [ 0.001; 0.005; 0.01; 0.05; 0.1; 0.5; 1.0; 5.0; 10.0 ]
;;

let () = init ()
