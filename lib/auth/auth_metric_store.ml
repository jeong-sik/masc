let metric_auth_strict_unknown_tool_denials = "masc_auth_strict_unknown_tool_denials_total"
let metric_auth_credential_index_cache_hits = "masc_auth_credential_index_cache_hits_total"
let metric_auth_credential_index_cache_misses = "masc_auth_credential_index_cache_misses_total"
let metric_auth_credential_ambiguous_lookup = "masc_auth_credential_ambiguous_lookup_total"
let metric_auth_bearer_token_mismatch = "masc_auth_bearer_token_mismatch_total"

let inc_counter _ ?labels:_ ?delta:_ () = ()
let set_gauge _ ?labels:_ _ = ()
