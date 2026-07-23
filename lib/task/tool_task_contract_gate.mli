(** Task lifecycle invariants unrelated to completion-quality judgment. *)

val strict_release_requires_handoff : Masc_domain.task option -> bool

val completion_state_error :
  task_id:string ->
  agent_name:string ->
  task_opt:Masc_domain.task option ->
  Masc_domain.masc_error option
