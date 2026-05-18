(** Auth, identity, config, and governance metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

val metric_auth_bearer_token_mismatch : string
val metric_auth_strict_unknown_tool_denials : string
val metric_auth_credential_token_duplicate : string
val metric_auth_credential_token_rotated : string
val metric_config_credential_archived_starvation : string
val metric_auth_bare_alias : string
val metric_auth_archive_epochs : string
val metric_auth_archive_pruned_total : string
val metric_auth_bare_alias_outcome_total : string
val metric_auth_bare_alias_audit_ticks_total : string
val metric_auth_credential_ambiguous_lookup : string
val metric_silent_auth_token_resolve_error : string
val metric_silent_dashboard_actor_fallback : string
val metric_auth_strict_would_reject : string
val metric_empty_tool_universe_observed : string
val metric_coord_join_normalize_outcome : string
val metric_config_unknown_keys_ignored : string
val metric_governance_judge_unparseable : string
val metric_governance_lenient_json_fallback_hit : string
