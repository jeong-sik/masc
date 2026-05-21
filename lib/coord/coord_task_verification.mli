(** Verification-evidence helpers for coord task lifecycle. *)

val flatten_lock_result : (('a, 'e) result, 'e) result -> ('a, 'e) result
val contains_substring_ci : string -> string -> bool
val is_placeholder_verification_evidence : string -> bool
val text_has_verification_artifact_ref : string -> bool
val evidence_ref_has_verification_artifact_ref : string -> bool
val notes_have_verification_artifact_ref : string -> bool
val verification_evidence_error_message : string

val verification_submission_evidence_refs
  :  Masc_domain.task
  -> notes:string
  -> Masc_domain.task_handoff_context option
  -> string list
