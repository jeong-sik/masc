(** Task_cache_invariant — Fleet-wide guard against stale task-cache emissions.

    Any keeper module that maintains its own task-state cache MUST use
    [with_fresh_task_status] before emitting broadcasts, mentions, or
    transitions tied to a specific task ID.  Callers that need finer control
    can compose [fresh_task_status] and [is_terminal] directly.

    @since #13397 *)

open Masc_domain
open Coord_utils

(** Read the current task status directly from the backlog.
    Returns [None] when the task is absent or the backlog cannot be read. *)
val fresh_task_status :
  Coord_utils_backend_setup.config -> task_id:string -> Masc_domain.task_status option

(** [is_terminal status] returns [true] iff [status] is [Done _] or
    [Cancelled _]. *)
val is_terminal : Masc_domain.task_status -> bool

(** Clear the agent's on-disk [current_task] when it equals [task_id] and
    log a [cache_desync.cleared] diagnostic event.

    Callers should invoke this before emitting a [cache_invalidated] broadcast
    to ensure the agent's state is clean before the message is sent. *)
val clear_stale_agent_task :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
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
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  task_id:string ->
  module_name:string ->
  (Masc_domain.task_status -> 'a) ->
  'a option
