(** Goal_verification_agent — the RFC-0387 stage-2 verifier caller.

    Application-owned LLM agent (not a Keeper) that drains the goal
    verification ledger's durable [Proof_pending] requests (B3), judges each
    through
    {!Task.Anti_rationalization.review} on the [verifier_exact] lane, and
    commits the verdict through {!Workspace_goals.commit_verifier_decision},
    the typed internal FSM+ledger+phase+event boundary, under the fixed
    identity [System_llm_agent { agent_run_id = "verifier_exact" }]
    (RFC-0361 D7(b)).

    Typed non-verdicts (evaluator unavailable, malformed reply after all
    slots failed, verdict without a stated reason, refused commit) leave the
    pending row durable and stop — a pending row is never consumed on
    failure, nothing re-runs the same review on a clock, and there is no
    wall-clock expiry. *)

val start :
  sw:Eio.Switch.t ->
  config:Workspace_utils_backend_setup.config ->
  unit

module For_testing : sig
  type pending_work = { goal_id : string }

  (** How one review ended. [Deferred] carries the reason no verdict was
      committed; the pending row it names is still durable. *)
  type process_outcome =
    | Committed
    | Deferred of string

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
