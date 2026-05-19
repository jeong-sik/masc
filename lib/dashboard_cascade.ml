(** Dashboard projection for cascade configuration and runtime health.

    Facade composed of cohesive submodules; each [include] below brings
    in one cluster of the dashboard cascade surface so the .mli contract
    stays in one place and submodules can be unit-tested in isolation.

    Submodules:
    - {!Dashboard_cascade_helpers}: shared JSON helpers, public profile
      name normalization, invalid-profile diagnostics, retention/query
      envelopes.
    - {!Dashboard_cascade_config}: [config_json], [raw_config_json],
      [save_raw_config_json], keeper -> cascade mapping rows.
    - {!Dashboard_cascade_health}: provider_info serializer +
      [provider_status] / [zero_provider_info].
    - {!Dashboard_cascade_recommendations}: Phase 2a low-trust operator
      recommendations.
    - {!Dashboard_cascade_health_json}: [health_json] aggregator-driven
      endpoint plus declared-provider scheme helpers.
    - {!Dashboard_cascade_capacity}: [client_capacity_json] +
      [client_capacity_history_json].
    - {!Dashboard_cascade_strategy_trace}: [strategy_trace_json].
    - {!Dashboard_cascade_audit_runs}: O1 audit_runs inspector.
    - {!Dashboard_cascade_slo}: in-process SLO snapshot. *)

include Dashboard_cascade_helpers
include Dashboard_cascade_config
include Dashboard_cascade_health
include Dashboard_cascade_recommendations
include Dashboard_cascade_health_json
include Dashboard_cascade_capacity
include Dashboard_cascade_strategy_trace
include Dashboard_cascade_audit_runs
include Dashboard_cascade_slo
