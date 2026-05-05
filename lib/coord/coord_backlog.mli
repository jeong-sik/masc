(** Coord backlog persistence — read / write the canonical
    [tasks/backlog.json] document with structural recovery. *)

open Masc_domain
open Coord_utils

val backlog_recovery_path : Coord_utils_backend_setup.config -> string
val decode_backlog : path:string ->
           Yojson.Safe.t -> (Masc_domain.backlog, string) result
val read_backlog_r : Coord_utils_backend_setup.config ->
           (Masc_domain.backlog, string) result
val read_backlog : Coord_utils_backend_setup.config -> Masc_domain.backlog
val write_backlog : Coord_utils_backend_setup.config -> Masc_domain.backlog -> unit
