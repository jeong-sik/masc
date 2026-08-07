(** Verification-evidence helpers. *)

val blank_evidence_ref : string -> bool
(** [true] when the entry trims to the empty string. Shared element-level
    predicate for evidence-ref boundary checks (RFC-0337 decision 4):
    boundaries reject flagged entries instead of silently dropping them. *)

val unresolvable_evidence_ref : string -> bool
(** [true] when {!Workspace_verification_store.classify_evidence_reference}
    answers [Unresolvable_reference] — the store would snapshot the entry as a
    payload-free invalid reference, which the reviewer must then read as
    unavailable evidence. Same boundary rule as {!blank_evidence_ref}: refuse
    it where the caller can still correct it. *)

val resolvable_evidence_ref_forms : string
(** The accepted reference forms, joined for an error message that has to tell
    a caller what to write instead. *)

val note_evidence_ref_form : string
(** The note form alone, for the sentence that tells a caller how to carry
    narrative. Taken from
    {!Workspace_verification_store.note_reference_form} so the prose cannot
    name a prefix the classifier no longer matches. *)

val non_empty_trimmed_strings : string list -> string list

(** task-1664: typed split of a task's verification evidence.
    [required_artifacts] are the artifacts the contract demands;
    [submitted_evidence] are the references the agent actually provided.

    It replaced a flat projection that concatenated both, so a verifier reading
    the list could not tell "the contract asked for a PR link" from "here is the
    submitted PR link". That projection was kept afterwards for
    byte-compatibility with existing consumers, and it had none -- no caller
    inside this module or outside it -- so it is gone. *)
type verification_evidence =
  { required_artifacts : string list
  ; submitted_evidence : string list
  }

val verification_evidence_to_yojson : verification_evidence -> Yojson.Safe.t

val verification_evidence_of_yojson :
  Yojson.Safe.t -> (verification_evidence, string) result

val concrete_verification_evidence :
  ?notes:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  ?submitted_evidence_refs:string list ->
  Masc_domain.task ->
  verification_evidence

(** JSON object fields [(required_artifacts, submitted_evidence)] for splicing
    into the verification request output / board meta / SSE payloads next to the
    unchanged [evidence_refs] field. *)
val verification_evidence_fields :
  verification_evidence -> (string * Yojson.Safe.t) list
