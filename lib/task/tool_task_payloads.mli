(** Pure payload builders and task-policy helpers. *)

val is_verdict_transition_action : Masc_domain.task_action -> bool

val terminal_verdict_noop_message :
  task_id:string -> action:string -> status:string -> string

val workflow_rejection_payload :
  ?rule_id:string ->
  ?scope_policy:string ->
  ?recoverable:bool ->
  ?extra_fields:(string * Yojson.Safe.t) list ->
  string ->
  Yojson.Safe.t

val workflow_rejection_payload_json :
  ?rule_id:string ->
  ?scope_policy:string ->
  ?recoverable:bool ->
  ?extra_fields:(string * Yojson.Safe.t) list ->
  string ->
  string

val build_claim_observation_payload :
  now:float ->
  agent_name:string ->
  task_id:string ->
  scope_widened:bool ->
  Yojson.Safe.t

val append_claim_observation :
  string ->
  now:float ->
  agent_name:string ->
  task_id:string ->
  scope_widened:bool ->
  string

val validate_task_id : string -> (string, Masc_domain.masc_error) result
