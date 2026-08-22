(** Task_cache_invariant — reads canonical task state and the subject's own
    record, keeping absence, unreadability, and disagreement apart.

    Neither lookup decides what happens next: the caller reads the returned
    variant and chooses to suppress, reject, or report a dependency failure.

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

(** What one agent record says about a task.  [Unreadable] carries the read or
    decode failure so a caller never reports a store it could not read as a
    subject that disagrees. *)
type agent_task_match =
  | Matches
  | Mismatch
  | Missing
  | Unreadable of string

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
    [task_id]. [Matches] is returned only after the record was rewritten and
    the desynchronization event was emitted; the other variants mean nothing
    was written. *)
val clear_stale_agent_task_if_matching :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  status_label:string ->
  module_name:string ->
  agent_task_match

(** Read the subject's current task under its per-agent file lock. *)
val agent_current_task_match :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  agent_task_match

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
