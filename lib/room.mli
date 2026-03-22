(** MASC Room - Core coordination hub.

    This module ties together all Room sub-modules (utils, state, lifecycle,
    init, status, task, walph, query, agent, portal, worktree, gc, vote,
    tempo, multi, rooms) and adds cross-cutting functions like room_enter. *)

(** {1 Included sub-modules} *)

include module type of Room_utils
include module type of Room_state
include module type of Room_lifecycle
include module type of Room_init
include module type of Room_status
include module type of Room_task
include module type of Room_task_schedule
include module type of Room_walph
include module type of Room_query
include module type of Room_portal
include module type of Room_worktree
include module type of Room_gc
include module type of Room_agent
include module type of Room_vote
include module type of Room_tempo
include module type of Room_multi
include module type of Room_rooms

(** {1 Room lifecycle (overrides)} *)

(** Initialize MASC room with optional auto-join.
    Wraps [Room_init.init] and calls [join] when [agent_name] is provided. *)
val init : config -> agent_name:string option -> string

(** {1 Multi-room (cross-cutting)} *)

val room_enter :
  config ->
  room_id:string ->
  ?agent_name:string ->
  agent_type:string ->
  unit -> Yojson.Safe.t
