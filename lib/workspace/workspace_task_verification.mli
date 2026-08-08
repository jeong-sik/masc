(** Verification-evidence helpers for task lifecycle.

    Completion judgment lives at the LLM Task-review boundary. *)

val flatten_lock_result : (('a, 'b) result, 'b) result -> ('a, 'b) result

val note_evidence_ref : string -> string option
  (** Normalize narrative text to the typed [note:] evidence wire form. *)

val verification_submission_evidence_refs :
  Masc_domain.task ->
  notes:string ->
  Masc_domain.task_handoff_context option ->
  string list
(** Return the producer's submitted evidence refs plus explicit [note:] entries
    for completion notes and handoff summaries. Contract requirements are not
    submitted evidence; the verification request carries them separately as
    [required_artifacts]. This helper makes no semantic sufficiency decision. *)
