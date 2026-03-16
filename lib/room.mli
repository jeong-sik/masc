(** MASC Room - Core coordination logic.

    This module ties together all Room sub-modules (utils, state, task,
    walph, query, agent, portal, worktree, gc, vote) and adds room-level
    functions for join, leave, init, status, tempo, and multi-room management. *)

(** {1 Included sub-modules} *)

include module type of Room_utils
include module type of Room_state
include module type of Room_task
include module type of Room_walph
include module type of Room_query
include module type of Room_portal
include module type of Room_worktree
include module type of Room_gc
include module type of Room_agent
include module type of Room_vote

(** {1 Room lifecycle} *)

val join :
  config ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?worktree:string option ->
  ?parent_task:string option ->
  unit -> string

val join_in_room :
  config ->
  room_id:string ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?worktree:string option ->
  ?parent_task:string option ->
  unit -> string

val leave : config -> agent_name:string -> string

val init : config -> agent_name:string option -> string

val pause : config -> by:string -> reason:string -> unit

val resume : config -> by:string -> [> `Already_running | `Resumed ]

val reset : config -> string

val status : config -> string

(** {1 Tempo control} *)

val read_tempo : config -> Types.tempo_config
val write_tempo : config -> Types.tempo_config -> unit
val get_tempo : config -> Yojson.Safe.t

val set_tempo :
  config ->
  mode:string ->
  reason:string option ->
  agent_name:string -> string

(** {1 Multi-room management} *)

val read_current_room : config -> string option
val write_current_room : config -> string -> unit
val room_path : config -> string -> string
val count_agents_in_room : config -> string -> int
val rooms_list : config -> Yojson.Safe.t

val room_create :
  config -> name:string -> description:string option -> Yojson.Safe.t

val ensure_room_entry : config -> string -> unit

val room_enter :
  config ->
  room_id:string ->
  ?agent_name:string ->
  agent_type:string ->
  unit -> Yojson.Safe.t
