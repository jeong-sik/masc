(** Verification-evidence helpers for task lifecycle.

    Substring-classifier predicates were retired in Phase E (RFC-0109
    closeout). The legacy [text_has_verification_artifact_ref] /
    [evidence_ref_has_verification_artifact_ref] /
    [notes_have_verification_artifact_ref] /
    [verification_evidence_error_message] are gone. Completion judgment lives
    at the LLM Task-review boundary. *)

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
