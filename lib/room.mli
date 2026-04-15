(** MASC Room - Core coordination hub.

    This module ties together all Room sub-modules (utils, state, lifecycle,
    init, status, task, query, agent, portal, worktree, gc). *)

(** {1 Included sub-modules} *)

include module type of Room_utils
include module type of Room_state
include module type of Room_broadcast
include module type of Room_lifecycle
include module type of Room_init
include module type of Room_status
include module type of Room_task
include module type of Room_task_schedule
include module type of Room_query
include module type of Room_portal
include module type of Room_worktree
include module type of Room_gc
include module type of Room_agent
(** {1 Room lifecycle (overrides)} *)

(** Initialize MASC room with optional auto-join.
    Wraps [Room_init.init] and calls [join] when [agent_name] is provided. *)
val init : config -> agent_name:string option -> string
