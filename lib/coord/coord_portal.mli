(** Portal coordination — agent-to-agent (A2A) bridge state.

    Manages [.masc/portals/] lifecycle: opening a portal between two
    agents, sending messages, and reporting status. *)

open Types
open Coord_utils

val portals_dir : Coord_utils_backend_setup.config -> string
val a2a_tasks_dir : Coord_utils_backend_setup.config -> string
val gen_a2a_task_id : unit -> string

val with_two_file_locks :
  Coord_utils_backend_setup.config ->
  string -> string -> (unit -> 'a) -> 'a

val portal_open_r :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  target_agent:string ->
  initial_message:string option ->
  string Types.masc_result

val portal_send_r :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  message:string ->
  string Types.masc_result

val get_portal_target :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  string option

val portal_close :
  Coord_utils_backend_setup.config -> agent_name:string -> string

(** Portal status snapshot as JSON: portal_from / portal_target /
    portal_status / task_count and friends. *)
val portal_status :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  Yojson.Safe.t
