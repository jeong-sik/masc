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

val scan_skipped_log_prefix : string
(** [goal verifier scan skipped] — the first words of the one WARN line each
    scan the goal store refused writes (RFC-0444 §2.3 row 7, criterion 3:
    line count = skipped scan count). The same scan appends one
    {!Goal_verification_run_registry.Scan_skipped} row. *)

(** Which scan step could not settle a Verifying goal: replaying the proof
    already committed, or re-arming its pending request. *)
type reconcile_step =
  | Reconcile_proof
  | Rearm_proof

val reconcile_step_to_string : reconcile_step -> string
val reconcile_step_of_string : string -> reconcile_step option

val unreconciled_to_yojson : Goal_store.goal -> Yojson.Safe.t
(** [null], or [{step; detail}] when the latest completed scan could not
    settle this still-Verifying goal. Recomputed by every scan and never
    stored, so it names the goals stuck in Verifying now. *)

module For_testing : sig
  val scan_active_once : unit -> bool
  (** Consume one pending scan on the real active runtime for deterministic
      wake/ownership race tests. False means no runtime is active. *)
  type pending_work = { goal_id : string }

  (** How one review ended. [Deferred] carries the reason no verdict was
      committed; the pending row it names is still durable. *)
  type process_outcome =
    | Committed
    | Superseded
    | Deferred of string

  (** Why a scan produced no work: the goal store this build cannot read.
      It is recorded as a durable row and a WARN line. *)
  type scan_failure = Scan_skipped of Goal_store.unavailable

  (** One Verifying goal whose ledger the scan could read but not reconcile
      or re-arm. The scan skips it and keeps collecting the other goals; the
      scan that calls {!collect_pending} logs it at ERROR, and its pending
      row stays durable. *)
  type reconcile_failure =
    { failed_goal_id : string
    ; step : reconcile_step
    ; failure : Goal_store.write_error
    }

  type scan =
    { collected : pending_work list
    ; unreconciled : reconcile_failure list
    }

  val scan_failure_to_string : scan_failure -> string
  (** For a test's failure message; nothing branches on it. *)

  val collect_pending :
    Workspace_utils_backend_setup.config ->
    (scan, scan_failure) result
  (** Reconciles or re-arms only currently-Verifying Goals through
      authoritative, locked reads. A goal that fails reconciliation lands in
      [unreconciled] and does not stop the other goals from being collected.
      It writes the Goal store when it reconciles or re-arms a proof, and
      writes no log: the row and the WARN line for a skipped scan, and the
      ERROR line for each unreconciled goal, come from the scan that calls it
      ({!drain_once}, the daemon). *)

  val process_pending_work :
    ?sw:Eio.Switch.t option ->
    Workspace_utils_backend_setup.config ->
    pending_work ->
    process_outcome

  val drain_once :
    ?sw:Eio.Switch.t option ->
    Workspace_utils_backend_setup.config ->
    (unit, scan_failure) result
  (** Synchronous single scan + process of every pending row. Tests use this
      instead of booting the daemon. A scan the store refused is recorded
      exactly as the daemon records it — one WARN line, one row — and is
      still returned as [Error (Scan_skipped _)]. *)
end
