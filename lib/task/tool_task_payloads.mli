(** Pure payload builders and task-policy helpers. *)

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
