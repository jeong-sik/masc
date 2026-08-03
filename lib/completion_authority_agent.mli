(** System LLM completion-authority lane.

    This lane is an application-owned LLM agent. It is not a Keeper, does not
    register a Keeper, and does not enter the Keeper task-action FSM. It reads
    an immutable verification request/evidence snapshot and commits a typed
    completion verdict through the workspace authority boundary. *)

val start : sw:Eio.Switch.t -> config:Workspace_utils_backend_setup.config -> unit

module For_testing : sig
  val evidence_refs_of_output :
    Yojson.Safe.t -> (string list, string) result

  val completion_verdict_of_review :
    Task.Anti_rationalization.verdict -> Masc_domain.completion_verdict

  val review_notes :
    request:Verification.verification_request ->
    evidence_access:Workspace_verification_store.submitted_evidence_access ->
    result:Task.Anti_rationalization.review_result ->
    authority:Masc_domain.completion_authority ->
    string
end
