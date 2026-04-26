(** coord_portal inferred mli **)

open Types
open Coord_utils



val portals_dir : Coord_utils_backend_setup.config -> string
val a2a_tasks_dir : Coord_utils_backend_setup.config -> string
val gen_a2a_task_id : unit -> string
val with_two_file_locks : Coord_utils_backend_setup.config ->
           string -> string -> (unit -> 'a) -> 'a
val portal_open_r : Coord_utils_backend_setup.config ->
           agent_name:string ->
           target_agent:string ->
           initial_message:string option -> string Types.masc_result
val portal_send_r : Coord_utils_backend_setup.config ->
           agent_name:string -> message:string -> string Types.masc_result
val get_portal_target : Coord_utils_backend_setup.config ->
           agent_name:string -> string option
val portal_close : Coord_utils_backend_setup.config -> agent_name:string -> string
val portal_status : Coord_utils_backend_setup.config ->
           agent_name:string ->
           [> `Assoc of
                (string *
                 [> `Assoc of
                      (string * [> `Int of int | `String of string ]) list
                  | `Int of int
                  | `String of string ])
                list ]
