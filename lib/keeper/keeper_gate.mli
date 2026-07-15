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
    suspending the caller. Explicit Keeper/workspace Always Allow modes are
    configuration choices, not remembered approvals. A supplied one-shot
    grant that cannot be consumed returns [Unavailable] without evaluating a
    second authorization path, so the durable grant remains single-use. *)
val decide :
  ?cycle_grant:cycle_grant ->
  keeper_always_allow:bool ->
  request ->
  decision

(** Recover durable Auto Judge work for exactly one workspace: restart
    [Summary_pending], finalize decisive [Summary_available], and retry only
    [Summary_failed { retryable = true }]. Every candidate id has an explicit
    started, finalized, skipped, or failed outcome. *)
val resume_persisted_auto_judges :
  base_path:string -> auto_judge_resume_report

val authorization_source_to_string : authorization_source -> string
val deferred_reason_to_string : deferred_reason -> string
val unavailable_reason_to_string : unavailable_reason -> string
val decision_to_yojson : decision -> Yojson.Safe.t
