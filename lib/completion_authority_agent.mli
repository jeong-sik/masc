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

  (** How one review attempt ended. [Deferred] carries no payload: a review
      that did not commit a verdict is reported to the Board and the producer
      Keeper chooses what happens next. [Retryable_deferred] means the typed
      evaluator error was retryable and the application-owned lane must
      re-arm its maintenance scan while the Task stays awaiting verification. *)
  type process_outcome =
    | Committed
    | Deferred
    | Retryable_deferred

  val process_outcome_of_evaluator_retryable : bool option -> process_outcome
  (** [Some true] is the only automatic-retry authority. [Some false] and
      [None] preserve the producer/operator action contract. *)

  type review_key =
    { task_id : string
    ; verification_id : string
    }

  val retain_settled
    :  awaiting:review_key list
    -> review_key list
    -> review_key list
  (** Which already-settled review keys a backlog read still shows as awaiting
      verification. [process_pending] is a level read over the whole backlog, so
      any unrelated submission re-scans every awaiting Task; a [Deferred] key is
      held back from those re-scans until the producer or operator moves, and
      this drops it again once the Task advances or is re-submitted under a new
      [verification_id]. Suppression is per key, never per Task, so a fresh
      submission is never held back. Pure, so the pruning rule is checkable
      without a backlog or an Eio runtime. *)
end
