(** Coord lifecycle — agent join / leave and registry parse-error
    diagnostics. *)

open Masc_domain
open Coord_utils
open Coord_state
open Coord_broadcast

(** JSON snapshot used when an agent file fails to parse — surfaces
    [agent_name], [agent_file], and a short error message. *)
val agent_parse_error_snapshot :
  agent_name:string -> agent_file:string -> Yojson.Safe.t

val join :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?worktree:string option ->
  ?parent_task:string option ->
  ?keeper_name:string option ->
  ?keeper_id:string option ->
  unit ->
  string

val leave :
  Coord_utils_backend_setup.config -> agent_name:string -> string
