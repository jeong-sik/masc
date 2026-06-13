(** Pure payload builders and task-policy helpers. *)

val transition_action_denylist_prefix : string

val normalize_transition_action : string -> string

val transition_action_denylist_entry : string -> string

val is_transition_action_denylist_entry : string -> bool

val transition_action_denied_by_denylist :
  tool_denylist:string list -> action:string -> bool

val transition_action_policy_applies : string list -> bool

val transition_action_allowed_actions : tool_denylist:string list -> string list

val is_verdict_transition_action : Masc_domain.task_action -> bool

val transition_action_policy_rejection :
  agent_name:string -> action:string -> allowed_actions:string list -> string

val terminal_verdict_noop_message :
  task_id:string -> action:string -> status:string -> string

val workflow_rejection_payload_json :
  ?rule_id:string ->
  ?tool_suggestion:string ->
  ?hint:string ->
  ?scope_policy:string ->
  ?alternatives:string list ->
  ?extra_fields:(string * Yojson.Safe.t) list ->
  string ->
  string

val build_claim_observation_payload :
  now:float -> agent_name:string -> task_id:string -> Yojson.Safe.t

val append_claim_observation :
  string -> now:float -> agent_name:string -> task_id:string -> string

val verdict_to_string : Anti_rationalization.review_result -> string

val is_cross_runtime_verdict : Anti_rationalization.review_result -> bool

val build_verdict_sse_payload :
  now:float ->
  task_id:string ->
  req:Anti_rationalization.review_request ->
  result:Anti_rationalization.review_result ->
  Yojson.Safe.t

val validate_task_id : string -> (string, Masc_domain.masc_error) result
