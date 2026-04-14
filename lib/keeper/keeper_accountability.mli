type claim_kind =
  | Task_commitment
  | Completion_claim

type claim_status =
  | Pending
  | Supported
  | Unsupported
  | Expired
  | Partial

val record_task_transition :
  Room_query.config ->
  agent_name:string ->
  task_id:string ->
  transition:string ->
  details:Yojson.Safe.t ->
  unit

val record_completion_claim :
  Room_query.config ->
  keeper_name:string ->
  agent_name:string ->
  trace_id:string ->
  turn_number:int ->
  subject:string ->
  ?task_id:string ->
  ?evidence_refs:string list ->
  ?surface:string ->
  strong_evidence:bool ->
  strong_evidence_refs:string list ->
  unit ->
  unit

val accountability_summary_json :
  Room_query.config ->
  keeper_name:string ->
  agent_name:string ->
  Yojson.Safe.t

val accountability_risk_is_high :
  Room_query.config ->
  keeper_name:string ->
  agent_name:string ->
  bool
