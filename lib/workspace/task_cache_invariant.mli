(** Task_cache_invariant — Fleet-wide guard against stale task-cache emissions.

    Any keeper module that maintains its own task-state cache MUST use
    [with_fresh_task_status] before emitting broadcasts, mentions, or
    transitions tied to a specific task ID.  Callers that need finer control
    can compose [fresh_task_status] and [is_terminal] directly.

    @since #13397 *)


(** Result of reading one task from the canonical backlog. *)
type fresh_task_lookup =
  | Found of Masc_domain.task_status
  | Absent
  | Unavailable of string

(** Read the current task status directly from the backlog without collapsing
    an absent task and an unreadable canonical store. *)
val read_fresh_task_status :
  Workspace_utils_backend_setup.config -> task_id:string -> fresh_task_lookup

(** Compatibility projection for callers that intentionally treat both
    [Absent] and [Unavailable _] as [None]. New invariant code should use
    {!read_fresh_task_status}. *)
val fresh_task_status :
  Workspace_utils_backend_setup.config -> task_id:string -> Masc_domain.task_status option

(** [is_terminal status] returns [true] iff [status] is [Done _] or
    [Cancelled _]. *)
val is_terminal : Masc_domain.task_status -> bool

(** Clear the agent's on-disk [current_task] when it equals [task_id] and
    log a [cache_desync.cleared] diagnostic event.

    Callers should invoke this before emitting a [cache_invalidated] broadcast
    to ensure the agent's state is clean before the message is sent. *)
val clear_stale_agent_task :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  status:Masc_domain.task_status ->
  module_name:string ->
  unit

(** Atomically clear the subject only when its current task exactly matches
    [task_id]. Returns [true] only after a matching record was rewritten and
    the desynchronization event was emitted. *)
val clear_stale_agent_task_if_matching :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  status_label:string ->
  module_name:string ->
  bool

(** Check the subject's current task under its per-agent file lock. Missing,
    malformed, or mismatched records return [false]. *)
val agent_current_task_matches :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  bool

(** Scan every on-disk agent record and clear [current_task] when it equals
    [task_id].  Use this when the backlog no longer references the task
    (terminal status or deletion) and the exact previous assignee is not
    known.  Logs one [cache_desync.cleared] event per affected agent.

    The read is best-effort and unlocked; {!clear_stale_agent_task}
    re-checks the match under the per-agent file lock before writing. *)
val clear_stale_agent_task_for_task :
  Workspace_utils_backend_setup.config ->
  task_id:string ->
  status:Masc_domain.task_status ->
  module_name:string ->
  unit

(** Core invariant wrapper.

    [with_fresh_task_status config ~agent_name ~task_id ~module_name f]
    verifies that [task_id] is non-terminal before calling [f].

    - If the backlog shows [task_id] as terminal: clears agent state, logs the
      desync, and returns [None].  Callers MUST skip the original emission.
    - If the task is active: calls [f status] and returns [Some result].
    - If the task is not found: returns [None] (conservative; callers that need
      to distinguish terminal from absent should use [fresh_task_status] directly). *)
val with_fresh_task_status :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  module_name:string ->
  (Masc_domain.task_status -> 'a) ->
  'a option
