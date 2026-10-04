(** Workspace_goals — Goal-management MCP tool handlers.

    Reachable from {!Tool_workspace.dispatch} for goal list, upsert, and
    transition operations. Goal data is persisted via {!Goal_store};
    this module owns parsing, validation, and response shapes. *)

(** [handle_goal_list ctx args] handles [masc_goal_list].
    Optional filter: [phase] (executing / verifying / awaiting_confirmation / completed / dropped).
    Returns the goal list with a
    rollup summary.  Validation errors return
    [(false, error_json)] without touching the store. *)
val handle_goal_list
  :  tool_name:string
  -> start_time:Tool_timing.started
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_upsert ctx args] handles [masc_goal_upsert] —
    create-or-update a goal record. Validates priority and rejects lifecycle
    fields, which belong to [masc_goal_transition]. Lifecycle field errors are
    reported via the dedicated
    [goal_upsert_lifecycle_error] formatter. A committed write remains successful
    if a subsequent event append fails. [event_recordings] reports each snapshot,
    criterion-induced phase event and exact due-date/priority edit event as
    [recorded] or [failed]; a failed entry
    carries the attempted payload and error. Cancellation still propagates. *)
val handle_goal_upsert
  :  tool_name:string
  -> start_time:Tool_timing.started
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** Record an explicit Goal measurement with evidence for the current
    success-criterion revision. This does not certify completion. *)
val handle_goal_measure
  :  tool_name:string
  -> start_time:Tool_timing.started
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_transition ctx args] handles
    [masc_goal_transition].  Required arg: [action] (one of
    {!Goal_phase.Public_action.all}). [request_complete] moves an executing
    Goal to [Verifying]. Repeating it while a proof remains pending preserves
    the idempotent [Already] response and emits a fresh verifier scan wake;
    verifier verdicts are not public actions.

    [drop] decides against the current Goal under its store lock and commits
    the phase and audit intent together. A committed cancellation remains a
    success when effect delivery is deferred; [effect_delivery] reports that
    separately. A repeated drop preserves the original Goal and drains the
    pending outbox without duplicating its event or verifier cancellation. *)
val handle_goal_transition
  :  tool_name:string
  -> start_time:Tool_timing.started
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

type verifier_decision =
  | Proof_proven
  | Proof_refuted of { reason : string }

type proof_reconciliation =
  | No_committed_proof
  | Reconciled of Goal_phase.t
  | Reconciliation_not_needed of Goal_phase.t

val verifier_authority : Masc_domain.completion_authority
(** The fixed authority of the Goal verifier: every proof verdict it commits
    and every stalled-review notice it posts carries this value. It is built
    inside the application boundary and is never read from a caller. *)

(** A step a caller of a Goal transition supplies. It runs under the Goal lock
    after the transition was checked and before anything is written for it.
    [Error] refuses the transition: nothing is written and the caller gets the
    message. This module does not know what a step does. *)
type proof_step = Goal_store.goal -> Goal_verification.verdict -> (unit, string) result

type confirmation_step =
  Goal_store.goal
  -> Goal_verification.verdict
  -> Goal_verification.confirmation
  -> (unit, string) result

(** Commit one verdict from the application-owned Goal verifier. The fixed
    [verifier_exact] authority is constructed inside this boundary; callers
    cannot supply or impersonate it. The ledger commit precedes any phase
    write, and a stale/non-pending verdict is refused. An exact replay after
    the target phase committed returns success without rewriting state or
    repeating phase events and announcements.

    [before_proof_commit] runs for a [Proof_proven] verdict that moves the
    Goal, after the criterion and phase checks and before the verdict reaches
    the ledger. It does not run for a refutation, for a refused verdict, or
    for the replay of a verdict that is already stored. When it refuses, the
    request stays pending and the Goal stays in [Verifying]. *)
val commit_verifier_decision
  :  ?before_proof_commit:proof_step
  -> tool_name:string
  -> start_time:Tool_timing.started
  -> Workspace_utils_backend_setup.config
  -> goal_id:string
  -> verification_run_id:string
  -> request_id:string
  -> criterion:Goal_store.criterion
  -> decision:verifier_decision
  -> evidence:string
  -> Tool_result.result

val reconcile_committed_proof :
  Workspace_utils_backend_setup.config ->
  goal_id:string ->
  (proof_reconciliation, Goal_store.write_error) result
(** Converges the Goal phase after a crash between the durable proof verdict
    write and the phase/event write. The existing verdict is reused without a
    model call or ledger rewrite. *)

type goal_refusal = { code : Tool_args.error_code; message : string }
(** A goal call the transaction refused. [code] says whose it is to fix
    ({!Tool_args.failure_class_of_error_code}). *)

type proof_request_error =
  | Store of Goal_store.write_error
      (** The store could not be read or written. [Store_unavailable] carries
          the store's own value so the caller can answer the RFC-0444
          envelope. *)
  | Refused of goal_refusal
      (** The goal's phase or the caller's [evidence_refs] do not admit the
          request; nothing was written. *)

val request_current_proof : ?evidence_refs:string list -> Workspace_utils_backend_setup.config -> goal_id:string ->
  (Goal_store.goal * Goal_verification.record, proof_request_error) result
(** Bind a proof request and Verifying phase to the same current criterion. *)

val recover_current_proof : Workspace_utils_backend_setup.config -> goal_id:string ->
  (bool, Goal_store.write_error) result
(** Recover a missing/stale request only while the current Goal remains Verifying.
    [Ok false] means a concurrent phase change needs no recovery; no request is
    created and no other Goal in the scan is blocked. *)

val confirm_completion : ?after_confirmation:confirmation_step ->
  Workspace_utils_backend_setup.config -> goal_id:string ->
  operator_id:string -> request_id:string -> verification_run_id:string ->
  criterion_revision:string -> (Yojson.Safe.t, Goal_store.write_error) result
(** HTTP-only operator authority. Identity comes from token-bound CanAdmin,
    never the request body or agent tool surface. Exact current proof
    required; a binding that does not name it is [Rejected], and a store
    this build cannot read is [Store_unavailable] with its own value.

    [after_confirmation] runs after the confirmation reached the verification
    ledger and before the phase is written. It also runs when the confirmation
    is repeated for a Goal that is already [Completed], so it must give the
    same answer the second time. When it refuses, the confirmation stays
    recorded, the phase does not move, and confirming again runs it again. *)
