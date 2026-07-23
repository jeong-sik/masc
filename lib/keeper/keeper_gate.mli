(** Non-hierarchical authorization boundary for Keeper external effects.

    The Gate receives an already-normalized, opaque operation identity and its
    complete concrete input. It never parses a command, tool name, provider,
    connector, or product-specific payload. *)

type causal_context =
  { turn_id : int option
  ; snapshot : Yojson.Safe.t
  }
(** Exact outer-turn evidence captured before the tool call. The Gate stores
    and forwards [snapshot] without interpreting its fields. *)

type request =
  { keeper_name : string
  ; operation : string
  ; input : Yojson.Safe.t
  ; base_path : string
  ; causal_context : causal_context option
  ; task_id : string option
  ; goal_ids : string list
  ; continuation_channel : Keeper_continuation_channel.t option
  }

type authorization_source =
  | One_shot_resolution of string
  | Exact_always_rule of string
  | Keeper_always_allow
  | Workspace_always_allow

type authorization = { source : authorization_source }

type deferred_reason =
  | Human_requested
  | Judge_requested
  | Auto_judge_unavailable of string
  | Mode_state_invalid of string

type unavailable_reason =
  | Queue_storage_unavailable of Keeper_approval_queue.storage_error
  | Approval_grant_unavailable of Keeper_approval_queue.grant_error
  | Approval_grant_consumption_in_progress of string

type decision =
  | Allow of authorization
  | Deferred of
      { approval_id : string
      ; reason : deferred_reason
      }
  | Unavailable of unavailable_reason

type auto_judge_resume_failure =
  { approval_id : string
  ; reason : string
  }

type auto_judge_resume_report =
  { requested : int
  ; started_ids : string list
  ; finalized_ids : string list
  ; skipped_ids : string list
  ; failures : auto_judge_resume_failure list
  }

(** Mutable only to serialize consumption inside one Keeper cycle. The durable
    Gate journal, not the wake event, owns the exact authorization. A match
    requires the same workspace, Keeper, opaque operation identity, and
    canonical complete input; provenance fields never become constraints. *)
type cycle_grant

val cycle_grant_of_resolution :
  Keeper_event_queue.hitl_resolution -> cycle_grant option

(** Evaluate one exact external-effect request. [keeper_always_allow] is the
    explicit Keeper profile switch; it carries no inferred semantics. Manual,
    Auto Judge, and invalid-mode outcomes enqueue durably and return without
    suspending the caller. Explicit Keeper/workspace Always Allow modes do not
    depend on the optional exact-rule store being readable. A supplied one-shot
    grant that cannot be consumed returns [Unavailable] without evaluating a
    second authorization path, so the durable grant remains single-use. *)
val decide :
  ?cycle_grant:cycle_grant ->
  keeper_always_allow:bool ->
  request ->
  decision

(** Recover durable Auto Judge work for exactly one workspace. Each exact
    [(base_path, keeper_name)] owner evaluates only its oldest entry.
    Failed, quarantined, released, uncertain, or otherwise ineligible oldest
    state is a FIFO barrier: recovery never activates a later same-owner entry.
    Completion drains only that owner's FIFO. Decisive
    persisted unbound output retains its legacy direct-finalization behavior.
    Completed exact output is first idempotently strict-rewritten with the same
    identity and summary; only [Keeper_approval_queue.Fsync_completed] permits
    Gate finalization. Visible unconfirmed or failed rewrites leave the approval
    pending and record a recovery failure. Dispatch-uncertain, released,
    released-recovery-required, restart-quarantined, and quarantined entries
    never enter automatic restart recovery. Failed judgments are never retried
    merely because a process restarted. Every recovery candidate id has an
    explicit started, finalized, skipped, or failed outcome. *)
val resume_persisted_auto_judges :
  base_path:string -> auto_judge_resume_report

val retry_failed_auto_judge :
  base_path:string -> requested_by:string -> string -> (unit, string) result
(** Explicitly retry one failed Auto Judge summary. The stored [retryable]
    classification is diagnostic only; operator authority controls this state
    transition. The approval must belong to the authenticated workspace exactly.
    No cadence, restart hook, or retry budget calls it. *)

type operator_recovery_report =
  { reopened_ids : string list
  ; started_ids : string list
  ; queued : int
  }

(** Reopen recoverable request-local judgments after an explicit operator
    selection of Auto Judge, then activate one FIFO drain for each Keeper owner
    with eligible unbound work in the workspace. Restart-classified released
    work is first durably reset to unbound; every other exact-bound entry
    remains operator-visible but is never queued. *)
val request_operator_auto_judge_recovery :
  base_path:string -> (operator_recovery_report, string) result

val authorization_source_to_string : authorization_source -> string
val deferred_reason_to_string : deferred_reason -> string
val unavailable_reason_to_string : unavailable_reason -> string
val decision_to_yojson : decision -> Yojson.Safe.t

module For_testing : sig
  type exact_completion =
    id:string ->
    input_hash:string ->
    sequence:int ->
    slot_id:string ->
    call_id:string ->
    plan_fingerprint:string ->
    request_body_sha256:string ->
    summary:Keeper_approval_queue.hitl_context_summary ->
    ( Keeper_approval_queue.exact_attempt_transition
    , Keeper_approval_queue.exact_attempt_error )
      result

  val auto_judge_entry_ready :
    Keeper_approval_queue.pending_approval -> bool

  val ready_auto_judges_for_owner :
    base_path:string ->
    keeper_name:string ->
    Keeper_approval_queue.pending_approval list ->
    Keeper_approval_queue.pending_approval list

  val claim_auto_judge : Keeper_approval_queue.pending_approval -> bool
  val release_auto_judge : Keeper_approval_queue.pending_approval -> unit

  type hitl_worker_spawner =
    sw:Eio.Switch.t ->
    entry:Keeper_approval_queue.pending_approval ->
    on_summary:(Keeper_approval_queue.hitl_context_summary -> unit) ->
    on_finish:(Hitl_summary_worker.finish_outcome -> unit) ->
    unit ->
    (unit, string) result

  val spawn_auto_judge_entry_with_worker
    :  spawn_worker:hitl_worker_spawner
    -> Keeper_approval_queue.pending_approval
    -> (bool, string) result
  (** Run the production atomic claim, active-owner lifecycle, cleanup, and
      conclusive-only drain with only the worker spawner injected. *)

  val resume_persisted_auto_judges_with_exact_completion :
    complete_summary_exact_attempt:exact_completion ->
    base_path:string ->
    auto_judge_resume_report
end
