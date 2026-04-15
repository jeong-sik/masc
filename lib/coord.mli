(** MASC Coord - Core coordination hub.

    This module ties together all Coord sub-modules (utils, state, lifecycle,
    init, status, task, query, agent, portal, worktree, gc). *)

(** {1 Included sub-modules} *)

include module type of Coord_utils
include module type of Coord_state
include module type of Coord_broadcast
include module type of Coord_lifecycle
include module type of Coord_init
include module type of Coord_status
include module type of Coord_task
include module type of Coord_task_schedule
include module type of Coord_query
include module type of Coord_portal
include module type of Coord_worktree
include module type of Coord_gc
include module type of Coord_agent
(** {1 Coord lifecycle (overrides)} *)

(** Initialize MASC room with optional auto-join.
    Wraps [Coord_init.init] and calls [join] when [agent_name] is provided. *)
val init : config -> agent_name:string option -> string
