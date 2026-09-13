(** Workspace_goals — Goal-management MCP tool handlers.

    Reachable from {!Tool_workspace.dispatch} for goal list, upsert, and
    transition operations. Goal data is persisted via {!Goal_store};
    this module owns parsing, validation, and response shapes. *)

(** [handle_goal_list ctx args] handles [masc_goal_list].
    Optional filter: [phase] (executing / blocked / completed / etc.).
    Returns the goal list with a
    rollup summary.  Validation errors return
    [(false, error_json)] without touching the store. *)
val handle_goal_list
  :  tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_upsert ctx args] handles [masc_goal_upsert] —
    create-or-update a goal record. Validates priority and rejects lifecycle
    fields, which belong to [masc_goal_transition]. Lifecycle field errors are
    reported via the dedicated
    [goal_upsert_lifecycle_error] formatter. *)
val handle_goal_upsert
  :  tool_name:string
  -> start_time:float
  -> Workspace_types.context
  -> Yojson.Safe.t
  -> Tool_result.result

(** [handle_goal_transition ctx args] handles
    [masc_goal_transition].  Required arg: [action] (one of
    {!Goal_phase.Public_action.all}). [request_complete] moves an executing
    Goal to [Verifying]. Repeating it while a proof remains pending preserves
    the idempotent [Already] response and emits a fresh verifier scan wake;
    verifier verdicts are not public actions. *)
val handle_goal_transition
  :  tool_name:string
  -> start_time:float
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

(** Commit one verdict from the application-owned Goal verifier. The fixed
    [verifier_exact] authority is constructed inside this boundary; callers
    cannot supply or impersonate it. The ledger commit precedes any phase
    write, and a stale/non-pending verdict is refused. An exact replay after
    the target phase committed returns success without rewriting state or
    repeating phase events and announcements. *)
val commit_verifier_decision
  :  tool_name:string
  -> start_time:float
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
  (proof_reconciliation, string) result
(** Converges the Goal phase after a crash between the durable proof verdict
    write and the phase/event write. The existing verdict is reused without a
    model call or ledger rewrite. *)

val request_current_proof : ?evidence_refs:string list -> Workspace_utils_backend_setup.config -> goal_id:string ->
  (Goal_store.goal * Goal_verification.record, string) result
(** Bind a proof request and Verifying phase to the same current criterion. *)

val recover_current_proof : Workspace_utils_backend_setup.config -> goal_id:string ->
  (bool, string) result
(** Recover a missing/stale request only while the current Goal remains Verifying.
    [Ok false] means a concurrent phase change needs no recovery; no request is
    created and no other Goal in the scan is blocked. *)

val confirm_completion : Workspace_utils_backend_setup.config -> goal_id:string ->
  operator_id:string -> request_id:string -> verification_run_id:string ->
  criterion_revision:string -> (Yojson.Safe.t, string) result
(** HTTP-only operator authority. Identity comes from token-bound CanAdmin,
    never the request body or agent tool surface. Exact current proof required. *)
