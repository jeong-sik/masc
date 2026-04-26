(** coord_init inferred mli **)

open Types
open Coord_utils
open Coord_state
open Coord_broadcast



val init : Coord_utils_backend_setup.config -> agent_name:'a option -> string
val pause : Coord_utils_backend_setup.config ->
           by:string -> reason:string -> unit
val resume : Coord_utils_backend_setup.config ->
           by:string -> [> `Already_running | `Resumed ]
val reset : Coord_utils_backend_setup.config -> string
