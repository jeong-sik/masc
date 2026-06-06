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

let init () = ()

let () = init ()
