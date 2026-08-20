(** System LLM completion-authority lane.

    This lane is an application-owned LLM agent. It is not a Keeper, does not
    register a Keeper, and does not enter the Keeper task-action FSM. It reads
    an immutable verification request/evidence snapshot and commits a typed
    completion verdict through the workspace authority boundary. *)

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace_utils_backend_setup.config ->
  unit

module For_testing : sig
  val authority_actor : string
  (** The fixed authority identity (RFC-0361 D7(b)): the [verifier_exact]
      lane id, shared by every judgement so verdicts aggregate by actor. *)

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

  (** How one review attempt ended, decoupled from the Eio scheduling loop so
      the retry decision below is a pure function of it. *)
  type process_outcome =
    | Committed
    | Deferred of { retryable : bool }

  val should_schedule_retry : process_outcome -> bool
  (** Whether [process_task] should arm the maintenance-pulse retry timer for
      this outcome. [false] for [Committed] (nothing left to retry) and for
      [Deferred { retryable = false }] (retrying is known not to change the
      outcome) — [true] otherwise. *)
end
