(** Cascade_metrics — Prometheus emit helpers for cascade routing observability.

    Mirrors TLA+ invariants in runtime telemetry.

    @since 0.192.0 *)

let on_decision ~cascade_name ~decision_label =
  Prometheus.inc_counter Prometheus.metric_cascade_decisions
    ~labels:[ ("decision", decision_label); ("cascade", cascade_name) ]
    ()

let on_fallback ~cascade_name ~reason =
  Prometheus.inc_counter Prometheus.metric_cascade_fallbacks
    ~labels:[ ("reason", reason); ("cascade", cascade_name) ]
    ()

let on_exhausted ~cascade_name =
  Prometheus.inc_counter Prometheus.metric_cascade_providers_exhausted
    ~labels:[ ("cascade", cascade_name) ]
    ()

let on_phase_override ~phase ~from_cascade ~to_cascade =
  Prometheus.inc_counter Prometheus.metric_cascade_routing_phase_overrides
    ~labels:
      [ ("phase", phase)
      ; ("from_cascade", from_cascade)
      ; ("to_cascade", to_cascade)
      ]
    ()
