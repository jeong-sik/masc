(** Auth, identity, config, and governance metric-name constants.

    Included by {!Otel_metric_store} so existing callers keep using
    [Otel_metric_store.metric_*] bindings unchanged. *)

let metric_auth_bearer_token_mismatch = Otel_metric_store_core.declare_counter "masc_auth_bearer_token_mismatch_total"

let metric_auth_strict_unknown_tool_denials =
  Otel_metric_store_core.declare_counter "masc_auth_strict_unknown_tool_denials_total"
;;

let metric_auth_credential_token_duplicate =
  Otel_metric_store_core.declare_counter "masc_auth_credential_token_duplicate_total"
;;

let metric_auth_credential_token_rotated =
  Otel_metric_store_core.declare_counter "masc_auth_credential_token_rotated_total"
;;

let metric_auth_credential_ambiguous_lookup =
  Otel_metric_store_core.declare_counter "masc_auth_credential_ambiguous_lookup_total"
;;

let metric_auth_credential_hash_collision =
  Otel_metric_store_core.declare_counter "masc_auth_credential_hash_collision_total"
;;

let metric_auth_credential_index_cache_hits =
  Otel_metric_store_core.declare_counter "masc_auth_credential_index_cache_hits_total"
;;

let metric_auth_credential_index_cache_misses =
  Otel_metric_store_core.declare_counter "masc_auth_credential_index_cache_misses_total"
;;

let metric_silent_auth_token_resolve_error =
  Otel_metric_store_core.declare_counter "masc_silent_auth_token_resolve_error_total"
;;

let metric_silent_dashboard_actor_fallback =
  Otel_metric_store_core.declare_counter "masc_silent_dashboard_actor_fallback_total"
;;

let metric_auth_strict_would_reject = Otel_metric_store_core.declare_counter "masc_auth_strict_would_reject_total"
let metric_config_unknown_keys_ignored = Otel_metric_store_core.declare_counter "masc_config_unknown_keys_ignored_total"
let metric_governance_judge_unparseable = Otel_metric_store_core.declare_counter "masc_governance_judge_unparseable_total"

let metric_governance_strict_json_parse_reject =
  Otel_metric_store_core.declare_counter "masc_governance_strict_json_parse_reject_total"
;;

let metric_startup_internal_keeper_token_sync =
  Otel_metric_store_core.declare_counter "masc_startup_internal_keeper_token_sync_total"
;;
