(** Cascade routing, liveness, and provider-health metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

(** Counter: cascade strategy decisions emitted by the strategy layer. *)
val metric_cascade_strategy_decisions : string

val metric_cascade_capacity_events : string

(** RFC-0022 section 9 - would-be ([mode=observe]) and actual
    ([mode=enforce]) in-attempt liveness kills, broken down by failure class.

    Labels: [kind, mode, provider] where:
    - [kind] is [no_first_token | inter_chunk_idle | wall_exceeded | provider_error]
    - [mode] is [observe | enforce]
    - [provider] is the cascade label that produced the attempt

    Use the observe-mode counter to calibrate bootstrap and observed-success
    budgets against [scripts/diag-keeper-cycle.sh] before flipping attempt
    liveness to enforce. *)
val metric_cascade_attempt_liveness_kill : string

(** RFC-0022 PR-2 section 3 - per-attempt finalizer counter regardless of
    outcome. Labels: [cascade], [provider], [outcome] in {success | kill |
    wire_error}. The kill-rate is [kill_total / observed_total]. *)
val metric_cascade_attempt_liveness_observed : string

(** Histogram: time from cascade attempt start to first non-Done chunk (TTFT).
    Labels: [cascade], [provider] where [provider] is a bounded public
    provider bucket. *)
val metric_cascade_ttfb_seconds : string

(** Histogram: inter-chunk gap during streaming (TBT). Labels: [cascade],
    [provider] where [provider] is a bounded public provider bucket. *)
val metric_cascade_inter_chunk_seconds : string

(** Gauge: composite health score per cascade provider.
    [success_rate * speed_score * cost_score] in [0.0, 1.0].
    Labels: [provider_key]. *)
val metric_cascade_provider_health_score : string

(** Counter: cascade routing decisions emitted by [Cascade_fsm.decide].
    Labels: [decision] in [accept|accept_on_exhaustion|try_next|exhausted]. *)
val metric_cascade_decisions : string

(** Counter: cascade fallback transitions ([Try_next] outcomes).
    Labels: [reason] in [call_err|slot_full|accept_rejected|health_filter]. *)
val metric_cascade_fallbacks : string

(** Counter: terminal exhaustion events emitted when a cascade has no further
    provider candidates. *)
val metric_cascade_providers_exhausted : string

(** Counter: cascade routing phase overrides applied during decision.
    Labels: [phase], [from_cascade], [to_cascade]. *)
val metric_cascade_routing_phase_overrides : string

(** Total cascade label-ranking skips triggered by recent server-error (5xx)
    score decay for a provider. Labels: [provider_key]. *)
val metric_cascade_server_error_skip_total : string

(** Total cascade fallback_cascade cycles detected during [load_catalog].
    A cycle means a provider stall propagates through every cascade in the loop
    silently for 600s+ without escaping. Labels: [cascade] (the entry point of
    the detected cycle). *)
val metric_cascade_fallback_cycle_detected_total : string

(** Total bootstrap/runtime-catalog provider health probes intentionally
    skipped as advisory. Labels: [provider_name, profile_name]. *)
val metric_provider_health_probe_skipped : string

(** Last advisory provider health status observed by runtime catalog
    validation. Values: 0=unknown/skipped, 1=healthy, 3=unhealthy.
    Labels: [provider_name, profile_name, model_id]. *)
val metric_provider_actual_health_status : string

(** Total provider health probe errors observed during runtime catalog
    validation. Counter complement to [metric_provider_actual_health_status]:
    the gauge only shows the last observed status, so a sustained probe failure
    rate is otherwise invisible. Labels: [provider_name, profile_name]. *)
val metric_provider_health_probe_error : string
