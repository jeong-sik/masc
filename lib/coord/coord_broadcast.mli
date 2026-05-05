(** Coord broadcast — emit room-wide messages and the
    accompanying message-activity event. *)

open Masc_domain
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
           ?msg_type:string ->
           ?task_cache_invariant_checked:bool ->
           Coord_utils_backend_setup.config ->
           from_agent:string -> content:string -> string
