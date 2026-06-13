(** Retired Otel_metric_store facade.

    The Otel_metric_store exporter/registration stack was hard-cut; this module keeps
    the historical metric-name and in-process counter API as a compatibility
    boundary while callers are removed in follow-up slices. *)

include Otel_metric_store_core
include Otel_metric_names
include Otel_builtin_metric_names
include Otel_oas_metric_names
include Otel_runtime_metric_names
include Otel_core_metric_names
include Otel_policy_metric_names
include Otel_identity_metric_names
include Otel_transport_metric_names

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
