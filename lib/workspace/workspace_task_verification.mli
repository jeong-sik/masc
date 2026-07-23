(** Verification-evidence helpers for task lifecycle.

    Substring-classifier predicates were retired in Phase E (RFC-0109
    closeout). The legacy [text_has_verification_artifact_ref] /
    [evidence_ref_has_verification_artifact_ref] /
    [notes_have_verification_artifact_ref] /
    [verification_evidence_error_message] are gone. Completion judgment lives
    at the LLM Task-review boundary. *)

val flatten_lock_result : (('a, 'b) result, 'b) result -> ('a, 'b) result

val verification_submission_evidence_refs :
  Masc_domain.task ->
  notes:string ->
  Masc_domain.task_handoff_context option ->
  string list
(** Typed concat of non-empty evidence sources for the verifier request.
    Values are not classified by local vocabulary; their meaning is judged by
    the configured LLM. Pure observability metadata — no gating semantics. *)
