val accountability_emit_skip_metric : string
(** #10314: Otel_metric_store counter name surfaced for tests and dashboards.
    Labels:
    - [kind] ∈ task_transition | completion_claim
    - [reason] ∈ not_keeper_agent_name | empty_subject
    A non-zero rate on a keeper that has decisions.jsonl traffic
    indicates the fleet observability gap from #10314. *)

val record_task_transition :
  Workspace_query.config ->
  agent_name:string ->
  task_id:string ->
  transition:Masc_domain.task_action ->
  details:Yojson.Safe.t ->
  unit

val record_completion_claim :
  Workspace_query.config ->
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
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  Yojson.Safe.t

val accountability_summary_lookup :
  Workspace_query.config ->
  keeper_name:string ->
  agent_name:string ->
  Yojson.Safe.t

val enable_window_read_count_for_testing : unit -> unit
val disable_window_read_count_for_testing : unit -> unit
val window_read_count_for_testing : unit -> int

