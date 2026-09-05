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

  val verdict_question_of_request :
    Verification.verification_request ->
    (Task.Anti_rationalization.verdict_question, string) result
  (** The request-to-question mapping: pure, reads no store. *)

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

  type scan_scope =
    | Whole_backlog
    | Targets of review_key list

  val entries_in_scope
    :  scope:scan_scope
    -> (review_key * 'a) list
    -> (review_key * 'a) list
  (** The awaiting entries one wake is allowed to review. The submission hook
      receives [task], [assignee] and [verification_id]; forwarding that identity
      as [Targets] is what keeps one submission from re-reviewing every other
      awaiting Task. The level read over the whole backlog re-ran a settled
      review on identical input until a producer acted (task-443, 2026-08-23: 45
      attempts in 5h against the same 1,012,551-byte atom).

      [Whole_backlog] stays for boot recovery and for a failed backlog read,
      which have no key to name. Pure, so the scope rule is checkable without a
      backlog or an Eio runtime. *)

  (** RFC-0417 §4.1: what the system lane does with one Task, read off its
      status. A completion claim is reviewed; a cancel claim is handed to the
      operator without a prompt and recorded as
      [Verification_run_registry.Operator_routed]; any other status is not an
      obligation. Pure, so the routing is pinned without a runtime. *)
  type admission =
    | Review_completion
    | Operator_routed
    | Not_awaiting

  val admission_of_status : Masc_domain.task_status -> admission
end
