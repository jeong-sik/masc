(** Goal_verification_agent — the RFC-0387 stage-2 verifier caller.

    Application-owned LLM agent (not a Keeper) that drains the goal
    verification ledger's durable pending requests — [Criterion_pending] (B2)
    and [Proof_pending] (B3) — judges each through
    {!Task.Anti_rationalization.review} on the [verifier_exact] lane, and
    commits the verdict through {!Workspace_goals.handle_goal_transition}, the
    same FSM+ledger+phase+event path the MCP surface uses, under the fixed
    identity [System_llm_agent { agent_run_id = "verifier_exact" }]
    (RFC-0361 D7(b)).

    Typed non-verdicts (evaluator unavailable, malformed reply after all
    slots failed, verdict without a stated reason, refused commit) leave the
    pending row durable and schedule a maintenance-pulse retry — a pending
    row is never consumed on failure, and there is no wall-clock expiry. *)

val start :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  config:Workspace_utils_backend_setup.config ->
  unit

module For_testing : sig
  type pending_kind =
    | Criterion_check
    | Completion_proof

  type pending_work = {
    goal_id : string;
    kind : pending_kind;
  }

  (** How one review ended, decoupled from the Eio scheduling loop so the
      retry decision is a pure function of it. *)
  type process_outcome =
    | Committed
    | Deferred of { retryable : bool }

  val should_schedule_retry : process_outcome -> bool
  (** Whether the maintenance-pulse retry timer should arm for this outcome.
      [false] for [Committed] and for non-retryable deferrals. *)

  val collect_pending :
    Workspace_utils_backend_setup.config ->
    (pending_work list, string) result
  (** One ledger load per call, joined in memory; includes the P0-2
      cross-check that re-arms [mark_proof_pending] for a [Verifying] goal
      whose ledger row lost the durable proof request. *)

  val process_pending_work :
    ?sw:Eio.Switch.t option ->
    Workspace_utils_backend_setup.config ->
    pending_work ->
    process_outcome

  val drain_once :
    ?sw:Eio.Switch.t option ->
    Workspace_utils_backend_setup.config ->
    (unit, string) result
  (** Synchronous single scan + process of every pending row. Tests use this
      instead of booting the daemon. *)
end
