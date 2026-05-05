(** Coord status snapshot — render the room/agent state as a
    human-readable string for the [masc_status] tool. *)

open Masc_domain
open Coord_utils
open Coord_state

val status : Coord_utils_backend_setup.config -> string
