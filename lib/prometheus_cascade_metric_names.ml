(** Cascade routing, liveness, and provider-health metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_cascade_strategy_decisions = "masc_cascade_strategy_decisions_total"
let metric_cascade_capacity_events = "masc_cascade_capacity_events_total"
let metric_cascade_attempt_liveness_kill = "masc_cascade_attempt_liveness_kill_total"

let metric_cascade_attempt_liveness_observed =
  "masc_cascade_attempt_liveness_observed_total"
;;

let metric_cascade_ttfb_seconds = "masc_cascade_ttfb_seconds"
let metric_cascade_inter_chunk_seconds = "masc_cascade_inter_chunk_seconds"
let metric_cascade_provider_health_score = "masc_cascade_provider_health_score"
let metric_cascade_decisions = "masc_cascade_decisions_total"
let metric_cascade_fallbacks = "masc_cascade_fallbacks_total"
let metric_cascade_providers_exhausted = "masc_cascade_providers_exhausted_total"
let metric_cascade_routing_phase_overrides = "masc_cascade_routing_phase_overrides_total"
let metric_cascade_server_error_skip_total = "masc_cascade_server_error_skip_total"

let metric_cascade_fallback_cycle_detected_total =
  "masc_cascade_fallback_cycle_detected_total"
;;

let metric_provider_health_probe_skipped = "masc_provider_health_probe_skipped_total"
let metric_provider_actual_health_status = "masc_provider_actual_health_status"
let metric_provider_health_probe_error = "masc_provider_health_probe_error_total"
