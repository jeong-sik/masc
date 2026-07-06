(** Task_cache_invariant — Fleet-wide guard against stale task-cache emissions.

    Any keeper module that maintains its own task-state cache MUST use
    [with_fresh_task_status] before emitting broadcasts, mentions, or
    transitions tied to a specific task ID.  Callers that need finer control
    can compose [fresh_task_status] and [is_terminal] directly.

    @since #13397 *)

open Masc_domain
open Workspace_utils

(** Read the current task status directly from the backlog.
    [Ok None] means the task is absent in a successfully read backlog.
    [Error _] means the status is unknown because the backlog could not be
    read/decoded. *)
val fresh_task_status_result :
  Workspace_utils_backend_setup.config ->
  task_id:string ->
  (Masc_domain.task_status option, string) result

(** Compatibility wrapper around {!fresh_task_status_result}. Returns [None]
    for either absent task or unreadable backlog, but logs read failures. *)
val fresh_task_status :
  Workspace_utils_backend_setup.config -> task_id:string -> Masc_domain.task_status option

(** Emit an explicit diagnostic for callers that continue without a known
    fresh task status. *)
val report_status_read_error :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  module_name:string ->
  string ->
  unit

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
      to distinguish terminal from absent should use [fresh_task_status_result]
      directly). *)
val with_fresh_task_status_result :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  module_name:string ->
  (Masc_domain.task_status -> 'a) ->
  ('a option, string) result

(** Compatibility wrapper around {!with_fresh_task_status_result}. *)
val with_fresh_task_status :
  Workspace_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  module_name:string ->
  (Masc_domain.task_status -> 'a) ->
  'a option
