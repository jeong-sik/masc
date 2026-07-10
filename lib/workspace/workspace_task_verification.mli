(** Verification-evidence helpers for task lifecycle.

    Substring-classifier predicates were retired in Phase E (RFC-0109
    closeout). The legacy [text_has_verification_artifact_ref] /
    [evidence_ref_has_verification_artifact_ref] /
    [notes_have_verification_artifact_ref] /
    [verification_evidence_error_message] are gone — gating decisions
    live in [Task_completion_gate] only. *)

val flatten_lock_result : (('a, 'b) result, 'b) result -> ('a, 'b) result

val is_placeholder_verification_evidence : string -> bool
(** True for trimmed lowercase placeholders like ["draft"], ["tbd"],
    [""]. Used to keep the typed concat free of trash entries. *)

val declared_verification_evidence_refs :
  Masc_domain.task ->
  Masc_domain.task_handoff_context option ->
  string list
(** Declared evidence refs only: contract metadata
    ([verify_gate_evidence] @ [required_evidence]) plus [evidence_refs]
    from the handoff argument (falling back to the task's persisted
    handoff), normalized and placeholder-filtered. Excludes free-text
    summary/notes — same sources as
    [verification_submission_evidence_refs] minus prose. A pure
    projection; the transition-layer evidence gate (#23719, scoped by
    RFC-0323 Phase A) consumes it. *)

val verification_submission_evidence_refs :
  Masc_domain.task ->
  notes:string ->
  Masc_domain.task_handoff_context option ->
  string list
(** Typed concat of evidence sources for the verifier request output.
    Pure observability metadata — no gating semantics. *)
