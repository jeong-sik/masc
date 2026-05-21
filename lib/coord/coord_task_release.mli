(** Coord task release helpers. *)

val release_task_r :
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  ?expected_version:int ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  unit ->
  string Masc_domain.masc_result

val force_release_task_r :
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  unit ->
  string Masc_domain.masc_result

val force_done_task_r :
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  notes:string ->
  unit ->
  string Masc_domain.masc_result

val force_cancel_task_r :
  Coord_utils.config ->
  agent_name:string ->
  task_id:string ->
  reason:string ->
  unit ->
  string Masc_domain.masc_result
