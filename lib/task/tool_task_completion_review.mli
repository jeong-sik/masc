(** Completion-note review and verification-evidence helpers. *)

val can_review_completion :
  task_opt:Masc_domain.task option -> agent_name:string -> bool

val persisted_completion_contract :
  task_opt:Masc_domain.task option -> string list option

val completion_notes_example : string

val completion_rejection_message : ?allow_force:bool -> string -> string

val placeholder_evidence_refs : string list

val is_placeholder_evidence_ref : string -> bool

val non_empty_trimmed_strings : string list -> string list

val concrete_verification_evidence_refs :
  ?notes:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  Masc_domain.task ->
  string list

val verification_evidence_refs_for_task :
  ?handoff_context:Masc_domain.task_handoff_context ->
  Masc_domain.task ->
  string list
