(** Coord state — backlog, room state, and recovery helpers. *)

open Types
open Coord_utils

val default_room_state :
  Coord_utils_backend_setup.config -> Types_core.room_state

val ensure_room_bootstrap : Coord_utils_backend_setup.config -> unit
val generate_session_id : unit -> string
val get_hostname : unit -> string option
val get_tty : unit -> string option

val resolve_agent_name :
  Coord_utils_backend_setup.config -> string -> string

val task_id_to_int : string -> int option

val read_archive_task_ids : Coord_utils_backend_setup.config -> int list

val append_archive_tasks :
  Coord_utils_backend_setup.config -> Types_core.task list -> unit

val next_task_number :
  Coord_utils_backend_setup.config -> Types.backlog -> int

val read_backlog_r :
  Coord_utils_backend_setup.config ->
  (Types.backlog, string) result

val read_backlog : Coord_utils_backend_setup.config -> Types.backlog

val write_backlog :
  Coord_utils_backend_setup.config -> Types.backlog -> unit

val non_empty_string_opt : string option -> string option
val normalized_string_list : string list -> string list

(** Project a JSON entry of the [active_agents] array to the agent
    name it identifies, accepting either a bare [`String name] or
    an object with a [name]/[agent_name] field. *)
val recover_active_agent_name : Yojson.Safe.t -> string option

val recover_room_state :
  Coord_utils_backend_setup.config ->
  Yojson.Safe.t -> Types_core.room_state

val write_state :
  Coord_utils_backend_setup.config -> Types_core.room_state -> unit

val read_state : Coord_utils_backend_setup.config -> Types_core.room_state

val update_state :
  Coord_utils_backend_setup.config ->
  (Types_core.room_state -> Types_core.room_state) ->
  Types_core.room_state

val next_seq : Coord_utils_backend_setup.config -> int
val is_paused : Coord_utils_backend_setup.config -> bool

val pause_info :
  Coord_utils_backend_setup.config ->
  (string option * string option * string option) option

val heartbeat_timeout_seconds : float
val parse_iso_time_opt : string -> float option
val parse_iso_time : string -> float
val is_zombie_agent : agent_name:string -> string -> bool
val take : int -> 'a list -> 'a list
