(** Task-contract predicates and completion gate helpers. *)

val task_has_persisted_contract : Masc_domain.task option -> bool

val task_has_strict_persisted_contract : Masc_domain.task option -> bool

val contract_requires_verification : Masc_domain.task_contract -> bool

val task_requires_verification : Masc_domain.task option -> bool

val strict_release_requires_handoff : Masc_domain.task option -> bool

val completion_state_error :
  task_id:string ->
  agent_name:string ->
  task_opt:Masc_domain.task option ->
  Masc_domain.masc_error option

val persisted_contract_rejection :
  agent_name:string ->
  task_opt:Masc_domain.task option ->
  notes:string ->
  string option
