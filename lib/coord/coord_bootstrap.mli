(** Coord room bootstrap — initialize the default room state on
    first boot. *)

open Masc_domain
open Coord_utils

val default_room_state : Coord_utils_backend_setup.config -> Masc_domain.room_state
val ensure_room_bootstrap : Coord_utils_backend_setup.config -> unit
