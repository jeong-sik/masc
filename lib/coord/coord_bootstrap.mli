(** Coord coord bootstrap — initialize the default room state on
    first boot. *)

open Masc_domain
open Coord_utils

val default_coord_state : Coord_utils_backend_setup.config -> Masc_domain.coord_state
val ensure_coord_bootstrap : Coord_utils_backend_setup.config -> unit
