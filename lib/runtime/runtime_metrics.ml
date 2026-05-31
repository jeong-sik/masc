(** Runtime telemetry emitters (RFC-0206 cascade→Runtime rebirth).

    Re-homes the prometheus counter ticks that surviving consumers still call
    from the deleted [Cascade_metrics]. ONLY the consumer-referenced emitters
    are ported; the routing-aware aggregation in [Cascade_metrics]
    (depended on Cascade_routes/Cascade_runtime/Runtime_inference) is NOT
    restored — it was the routing layer RFC-0206 §5 discards.

    The prometheus metric-name strings are preserved verbatim
    ([masc_cascade_*_total]): they are an operator-facing seam (Grafana
    dashboards / alert rules query them by name), so renaming the module does
    not rename the series. *)

let metric_provider_cooldown = "masc_cascade_provider_cooldown_total"
let metric_cascade_metrics_eviction = "masc_cascade_metrics_eviction_total"
let metric_cascade_audit_failure = "masc_cascade_audit_failure_total"

let on_provider_cooldown ~provider ~reason =
  Prometheus.inc_counter
    metric_provider_cooldown
    ~labels:[ ("provider", provider); ("reason", reason) ]
    ()
;;

let on_cascade_metrics_eviction () =
  Prometheus.inc_counter metric_cascade_metrics_eviction ()
;;

let on_cascade_audit_failure ~stage =
  Prometheus.inc_counter metric_cascade_audit_failure ~labels:[ ("stage", stage) ] ()
;;
