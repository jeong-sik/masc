let metric_config_credential_archived_starvation =
  "masc_config_credential_archived_starvation_total"

let metric_auth_bare_alias_outcome_total = "masc_auth_bare_alias_outcome_total"
let metric_auth_bare_alias = "masc_auth_bare_alias"
let metric_auth_strict_unknown_tool_denials = "masc_auth_strict_unknown_tool_denials_total"
let metric_auth_bare_alias_audit_ticks_total = "masc_auth_bare_alias_audit_ticks_total"
let metric_auth_credential_index_cache_hits = "masc_auth_credential_index_cache_hits_total"
let metric_auth_credential_index_cache_misses = "masc_auth_credential_index_cache_misses_total"
let metric_auth_credential_ambiguous_lookup = "masc_auth_credential_ambiguous_lookup_total"
let metric_auth_bearer_token_mismatch = "masc_auth_bearer_token_mismatch_total"

let inc_counter _ ?labels:_ ?delta:_ () = ()
let set_gauge _ ?labels:_ _ = ()
