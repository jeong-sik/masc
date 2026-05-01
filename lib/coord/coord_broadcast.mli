(** Coord broadcast — emit room-wide messages and the
    accompanying message-activity event. *)

open Types
open Coord_utils

val emit_message_activity : Coord_utils_backend_setup.config ->
           from_agent:string ->
           content:string ->
           mention:string option ->
           ?session_id:string ->
           ?operation_id:string ->
           ?worker_run_id:string ->
           ?evidence_refs:string list -> unit -> unit
val broadcast_channel : Coord_utils_backend_setup.config -> string
val on_broadcast_mention : (string option -> unit) ref
val broadcast : ?trace_context:string ->
           Coord_utils_backend_setup.config ->
           from_agent:string -> content:string -> string

val broadcast_challenger_start :
  Coord_utils_backend_setup.config ->
  keeper_name:string ->
  challenger_cascade:string ->
  unit
(** Broadcast a challenger round start notification. *)

val broadcast_challenger_veto :
  Coord_utils_backend_setup.config ->
  keeper_name:string ->
  rule:string ->
  detail:string ->
  challenger_cascade:string ->
  unit
(** Broadcast a challenger veto result. *)
