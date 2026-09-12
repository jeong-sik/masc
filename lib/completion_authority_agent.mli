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

  (** What one review attempt asks of the retry scheduler. A request, not an
      outcome: whether a retry is armed is known only once the scheduler
      answers with a [retry_admission]. *)
  type retry_request =
    | Retry_requested
    | No_retry_requested

  (** The scheduler's answer to one request. [Armed_timer]: this request
      forked the timer, which fires after the lane's full interval.
      [Joined_running_timer]: the request added keys to a batch whose timer
      was already running. [Already_pending]: the pending batch already
      covered every key. *)
  type retry_admission =
    | Armed_timer
    | Joined_running_timer
    | Already_pending

  (** What happened to the retry after the attempt was recorded; the Board
      post is projected from this. *)
  type retry_scheduling =
    | Retry_not_requested
    | Retry_admitted of retry_admission

  (** Why a review stopped without a verdict. The registry row, the WARN
      line and the Board notice are all read off this sum. Only
      [Not_reviewed] carries a retry request: the evaluator's typed error is
      the only automatic-retry authority, so no other stop can ask for one. *)
  type stop_cause =
    | Infrastructure_unavailable of
        { stage : Verification_run_registry.infrastructure_stage
        ; detail : string
        }
    | Commit_failed of { detail : string }
    | Not_reviewed of
        { gate : string
        ; detail : string
        ; evaluator_runtime : string
        ; retry : retry_request
        }
    | Raised of { detail : string }

  (** How one review attempt ended. [Stalled] names why no verdict was
      committed: the run row is recorded, the caller schedules the retry the
      cause asks for, and then writes the WARN and projects the stall to the
      Board from the scheduler's answer. [Operator_routed] is a cancel claim
      handed to the operator without a review (RFC-0417 §4.1). *)
  type process_outcome =
    | Committed
    | Operator_routed
    | Stalled of stop_cause

  val retry_request_of_evaluator_retryable : bool option -> retry_request
  (** [Some true] is the only automatic-retry authority. [Some false] and
      [None] request nothing, preserving the producer/operator contract. *)

  val retry_request_of_stop_cause : stop_cause -> retry_request
  (** The request a stop carries: [Not_reviewed]'s own, [No_retry_requested]
      for every other constructor. *)

  val stop_cause_label : stop_cause -> string
  (** The constructor name with the payload an operator filters on, e.g.
      [Infrastructure_unavailable{stage=review_preparation}] or
      [Not_reviewed{gate=evaluator_unavailable,slot=ollama_cloud.deepseek}]. *)

  val stalled_gate : stop_cause -> string
  (** The [gate] the Board notice keys its repeat check on: the evaluator's
      gate for [Not_reviewed], [stop_cause_label] for every other stop. *)

  val stall_log_line
    :  task_id:string
    -> verification_id:string
    -> cause:stop_cause
    -> disposition:Verification_protocol.stall_disposition
    -> string
  (** The one WARN a review without a verdict writes, chosen by the same
      disposition the Board sentence is rendered from. [Retry_scheduled]
      says "will retry" and how soon ([in_sec=<seconds>] for a timer this
      stall armed, [in=shared_timer] for one it joined); [No_retry_armed]
      says "stopped: <label>; producer or operator must act". Neither says
      "deferred" alone. *)

  val announce_stall
    :  notify:
         (task_id:string
          -> verification_id:string
          -> gate:string
          -> detail:string
          -> disposition:Verification_protocol.stall_disposition
          -> unit)
    -> task_id:string
    -> verification_id:string
    -> cause:stop_cause
    -> disposition:Verification_protocol.stall_disposition
    -> unit
  (** Writes [stall_log_line] at WARN, then calls [notify] with
      [stalled_gate cause], the cause's detail and the same disposition. The
      WARN is written before [notify] runs. An ordinary exception out of
      [notify] is recorded as an ERROR line carrying the exception and does
      not escape; [Eio.Cancel.Cancelled] is re-raised. Production passes
      [Verification_protocol.notify_stalled_verification] with the lane's
      authority applied. *)

  val stall_disposition_of_scheduling
    :  retry_interval_sec:float
    -> retry_scheduling
    -> Verification_protocol.stall_disposition
  (** The Board disposition for one stall, from what the scheduler reported.
      [Retry_not_requested] is [No_retry_armed]; [Armed_timer] is
      [Retry_scheduled] after the full [retry_interval_sec];
      [Joined_running_timer] and [Already_pending] are [Retry_scheduled] on
      the [Shared_timer], since the delay that timer holds is not this
      request's to name. *)

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

  val make_retry_scheduler
    :  sw:Eio.Switch.t
    -> wait:(unit -> unit)
    -> dispatch:(scan_scope -> unit)
    -> scan_scope
    -> retry_admission
  (** The production retry scheduler with a caller-controlled interval and
      dispatch sink. [Armed_timer] means the request forked the timer;
      [Joined_running_timer] means new keys entered a batch whose timer was
      already running; [Already_pending] means the batch already covered every
      key. A whole-backlog request shares the batch and timer with named
      retries. The switch owns the timer and its cancellation. *)

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
