(** Auth, identity, config, and governance metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

val metric_auth_bearer_token_mismatch : string
val metric_auth_strict_unknown_tool_denials : string
val metric_auth_tool_permission_undeclared_denials : string
val metric_auth_credential_token_duplicate : string
val metric_auth_credential_token_rotated : string
val metric_auth_credential_ambiguous_lookup : string
val metric_auth_credential_hash_collision : string
val metric_auth_credential_index_cache_hits : string
val metric_auth_credential_index_cache_misses : string
val metric_silent_auth_token_resolve_error : string
val metric_silent_dashboard_actor_fallback : string
val metric_auth_strict_would_reject : string
val metric_config_unknown_keys_ignored : string
val metric_governance_judge_unparseable : string
val metric_governance_lenient_json_fallback_hit : string
val metric_startup_internal_keeper_token_sync : string
