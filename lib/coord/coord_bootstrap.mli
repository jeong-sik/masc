(** Coord room bootstrap — initialize the default room state on
    first boot. *)

open Types
open Coord_utils

val default_room_state : Coord_utils_backend_setup.config -> Types_core.room_state
val ensure_room_bootstrap : Coord_utils_backend_setup.config -> unit
