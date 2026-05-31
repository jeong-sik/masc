(** Workspace backlog persistence — read / write the canonical
    [tasks/backlog.json] document with structural recovery. *)

open Masc_domain
open Workspace_utils

val backlog_recovery_path : Workspace_utils_backend_setup.config -> string
val decode_backlog : path:string ->
           Yojson.Safe.t -> (Masc_domain.backlog, string) result
val read_backlog_r : Workspace_utils_backend_setup.config ->
           (Masc_domain.backlog, string) result
val read_backlog : Workspace_utils_backend_setup.config -> Masc_domain.backlog
val write_backlog : Workspace_utils_backend_setup.config -> Masc_domain.backlog -> unit
