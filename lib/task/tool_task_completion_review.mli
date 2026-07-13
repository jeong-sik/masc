(** Completion-note review and verification-evidence helpers. *)

val persisted_completion_contract :
  task_opt:Masc_domain.task option -> string list option

val blank_evidence_ref : string -> bool
(** [true] when the entry trims to the empty string. Shared element-level
    predicate for evidence-ref boundary checks (RFC-0337 decision 4):
    boundaries reject flagged entries instead of silently dropping them. *)

val non_empty_trimmed_strings : string list -> string list

val concrete_verification_evidence_refs :
  ?notes:string ->
  ?handoff_context:Masc_domain.task_handoff_context ->
  ?submitted_evidence_refs:string list ->
  Masc_domain.task ->
  string list

val verification_evidence_refs_for_task : Masc_domain.task -> string list

(** task-1664: typed split of a task's verification evidence. [required_artifacts]
    are the artifacts the contract demands; [submitted_evidence] are the
    references the agent actually provided. The flat
    {!concrete_verification_evidence_refs} concatenates both and cannot
    distinguish the two roles. *)
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
