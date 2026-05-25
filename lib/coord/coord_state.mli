(** Coord state — backlog, room state, and recovery helpers. *)

open Masc_domain
open Coord_utils

val normalized_string_list : string list -> string list

(** Project a JSON entry of the [active_agents] array to the agent
    name it identifies, accepting either a bare [`String name] or
    an object with a [name]/[agent_name] field. *)
val recover_active_agent_name : Yojson.Safe.t -> string option

val recover_room_state :
  Coord_utils_backend_setup.config ->
  Yojson.Safe.t -> Masc_domain.room_state

val write_state :
  Coord_utils_backend_setup.config -> Masc_domain.room_state -> unit

val read_state : Coord_utils_backend_setup.config -> Masc_domain.room_state

val update_state :
  Coord_utils_backend_setup.config ->
  (Masc_domain.room_state -> Masc_domain.room_state) ->
  Masc_domain.room_state

val next_seq : Coord_utils_backend_setup.config -> int
val is_paused : Coord_utils_backend_setup.config -> bool

val pause_info :
  Coord_utils_backend_setup.config ->
  (string option * string option * string option) option

val heartbeat_timeout_seconds : float
val parse_iso_time_opt : string -> float option
val parse_iso_time : string -> float
val is_zombie_agent : ?agent_type:string -> agent_name:string -> string -> bool
val take : int -> 'a list -> 'a list
