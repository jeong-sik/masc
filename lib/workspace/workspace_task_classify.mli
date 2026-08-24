(** Workspace_task_classify — State classification, task actor kind, working agents,
    event helpers.

    This module is [include]d by {!Workspace_task}; all bindings are part of
    the public Workspace interface.  Re-exports {!Workspace_utils} and
    {!Workspace_state}. *)

include module type of Workspace_utils
include module type of Workspace_state

(** {1 Task activity helpers} *)

(** Update the on-disk agent state record under its own
    [with_file_lock] on the agent file.  The callback receives the
    current agent record and returns the updated one; the helper
    silently skips writes when the agent file is missing (matching
    the pre-existing best-effort mirror semantics) and logs JSON
    parse failures with the agent name for diagnostic context.

    Callers that hold an outer lock on a different file (e.g. the
    backlog in [Workspace_task_schedule.claim_next_r]) must nest this
    call inside the outer lock; lock acquisition order is always
    {b outer path → agent file} across every call site to keep the
    graph acyclic.

    @since PR #6634 — previously inline at six sites in [Workspace_task]
    task transitions; exposed here so [Workspace_task_schedule] can reuse
    the same discipline for its own agent-state writes. *)
val update_local_agent_state
  :  config
  -> agent_name:string
  -> (Masc_domain.agent -> Masc_domain.agent)
  -> unit

type task_actor_kind =
  | Agent
  | Operator
  | System

(** Optional [correlation_id] / [run_id] are merged into the activity
    payload as additional fields when present. [actor_kind] defaults to
    [Agent]; system-owned mutations must pass [System] explicitly. Backed
    by [merge_envelope_into_payload]. *)
val emit_task_activity
  :  ?correlation_id:string
  -> ?run_id:string
  -> ?actor_kind:task_actor_kind
  -> config
  -> agent_name:string
  -> task_id:string
  -> kind:string
  -> payload:Yojson.Safe.t
  -> unit

val task_actor_kind_to_string : task_actor_kind -> string
(** Canonical wire representation for task activity actors. *)
val trim_opt : string option -> string option
val working_agents : config -> string list

(** Exact persisted task-owner comparison. Callers must supply the canonical
    actor identity; name-shape aliases have no ownership authority. *)
val same_task_actor : config -> string -> string -> bool

val normalize_task_contract : Masc_domain.task_contract -> Masc_domain.task_contract

(** [merge_execution_links existing ?session_id ?operation_id ()] keeps the
    identifiers already linked and adds the ones supplied. It touches only
    execution identity — completion criteria are written when the task is
    created and are not derived, defaulted, or rewritten anywhere. *)
val merge_execution_links
  :  Masc_domain.task_execution_links
  -> ?session_id:string
  -> ?operation_id:string
  -> unit
  -> Masc_domain.task_execution_links

val task_status_to_string : Masc_domain.task_status -> string
val task_assignee_of_status : Masc_domain.task_status -> string option

(** Issue #7646: actions that [transition_task_r] accepts from the given
    [task_status]. Used to enrich "Invalid transition" error messages so
    LLM keepers see what they SHOULD have called, not just what failed.
    Empty list for terminal states ([Done], [Cancelled]). *)
val valid_next_actions_for_status
  :  Masc_domain.task_status
  -> Masc_domain.task_action list

(** Issue #7646: rendered hint string suitable for embedding in error
    messages, e.g. [", valid_next_actions=[claim;cancel]"]. Returns the
    empty string for terminal states. *)
val next_actions_hint
  :  Masc_domain.task_status
  -> string

val task_started_at_unix : Masc_domain.task_status -> float

val task_transition_details
  :  from_status:Masc_domain.task_status
  -> to_status:Masc_domain.task_status
  -> ?notes:string
  -> ?reason:string
  -> ?duration_ms:int
  -> unit
  -> Yojson.Safe.t

val observe_task_transition
  :  config
  -> agent_name:string
  -> task_id:string
  -> transition:Masc_domain.task_action
  -> details:Yojson.Safe.t
  -> unit

(** {1 Transition event types} *)

type transition_event_type =
  | Task_transition
  | Task_cancelled

val transition_log_event
  :  event_type:transition_event_type
  -> ?actor_kind:task_actor_kind
  -> agent_name:string
  -> task_id:string
  -> from_status:Masc_domain.task_status
  -> to_status:Masc_domain.task_status
  -> ?action:string
  -> ?notes:string
  -> ?reason:string
  -> ?duration_ms:int
  -> ?handoff_context:Masc_domain.task_handoff_context
  -> ?assignee:string
  -> ?now:string
  -> unit
  -> Yojson.Safe.t
