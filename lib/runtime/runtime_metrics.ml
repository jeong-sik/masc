(** Runtime telemetry emitters (RFC-0206 runtime→Runtime rebirth).

    Re-homes the otel_metric_store counter ticks that surviving consumers still call
    from the deleted [Runtime_metrics]. ONLY the consumer-referenced emitters
    are ported; the routing-aware aggregation in [Runtime_metrics]
    (depended on Runtime_routes/Runtime_runtime/Runtime_inference) is NOT
    restored — it was the routing layer RFC-0206 §5 discards.

    The otel_metric_store metric-name strings are preserved verbatim
    ([masc_runtime_*_total]): they are an operator-facing seam (Grafana
    dashboards / alert rules query them by name), so renaming the module does
    not rename the series. *)

type audit_failure_stage =
  | Store_creation
  | Append

let audit_failure_stage_to_string = function
  | Store_creation -> "store_creation"
  | Append -> "append"
;;

let on_runtime_metrics_eviction () =
  Otel_metric_store_core.inc_counter
    Otel_runtime_metric_names.metric_runtime_metrics_eviction
    ()
;;

let on_runtime_audit_failure ~stage =
  Otel_metric_store_core.inc_counter
    Otel_runtime_metric_names.metric_runtime_audit_failure
    ~labels:[ "stage", audit_failure_stage_to_string stage ]
    ()
;;
