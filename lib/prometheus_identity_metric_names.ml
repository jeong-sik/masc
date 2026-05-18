(** Auth, identity, config, and governance metric-name constants.

    Included by {!Prometheus} so existing callers keep using
    [Prometheus.metric_*] bindings unchanged. *)

let metric_auth_bearer_token_mismatch = "masc_auth_bearer_token_mismatch_total"

let metric_auth_strict_unknown_tool_denials =
  "masc_auth_strict_unknown_tool_denials_total"
;;

let metric_auth_credential_token_duplicate =
  "masc_auth_credential_token_duplicate_total"
;;

let metric_auth_credential_token_rotated =
  "masc_auth_credential_token_rotated_total"
;;

let metric_config_credential_archived_starvation =
  "masc_config_credential_archived_starvation_total"
;;

let metric_auth_bare_alias = "masc_auth_bare_alias"
let metric_auth_archive_epochs = "masc_auth_archive_epochs"
let metric_auth_archive_pruned_total = "masc_auth_archive_pruned_total"

let metric_auth_bare_alias_outcome_total =
  "masc_auth_bare_alias_outcome_total"
;;

let metric_auth_bare_alias_audit_ticks_total =
  "masc_auth_bare_alias_audit_ticks_total"
;;

let metric_auth_credential_ambiguous_lookup =
  "masc_auth_credential_ambiguous_lookup_total"
;;

let metric_silent_auth_token_resolve_error =
  "masc_silent_auth_token_resolve_error_total"
;;

let metric_silent_dashboard_actor_fallback =
  "masc_silent_dashboard_actor_fallback_total"
;;

let metric_auth_strict_would_reject = "masc_auth_strict_would_reject_total"
let metric_empty_tool_universe_observed = "masc_empty_tool_universe_observed_total"
let metric_coord_join_normalize_outcome = "masc_coord_join_normalize_outcome_total"
let metric_config_unknown_keys_ignored = "masc_config_unknown_keys_ignored_total"
let metric_governance_judge_unparseable = "masc_governance_judge_unparseable_total"

let metric_governance_lenient_json_fallback_hit =
  "masc_governance_lenient_json_fallback_hit_total"
;;
