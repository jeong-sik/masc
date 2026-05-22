(** Diagnostic helpers for "no eligible task" responses. *)

val no_eligible_diagnostics_json
  :  excluded_count:int
  -> blocked_count:int
  -> verification_blocked_count:int
  -> scope_excluded_count:int
  -> required_tool_excluded_count:int
  -> explicit_excluded_count:int
  -> claim_pool_candidate_count:int
  -> receipt_required_tool_blocked:bool
  -> agent_tool_names_known:bool
  -> Yojson.Safe.t

val no_eligible_blocker_summary
  :  blocked_count:int
  -> verification_blocked_count:int
  -> scope_excluded_count:int
  -> required_tool_excluded_count:int
  -> string
