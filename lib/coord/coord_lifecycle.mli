(** Coord lifecycle — agent join / leave and registry parse-error
    diagnostics. *)

open Masc_domain
open Coord_utils
open Coord_state
open Coord_broadcast

val join :
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  ?agent_type_override:string option ->
  capabilities:string list ->
  ?pid:int option ->
  ?hostname:string option ->
  ?tty:string option ->
  ?parent_task:string option ->
  ?keeper_name:string option ->
  ?keeper_id:string option ->
  unit ->
  string

val leave :
  ?stop_heartbeats:bool ->
  Coord_utils_backend_setup.config ->
  agent_name:string ->
  string
