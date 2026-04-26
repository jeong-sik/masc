(** coord_agent inferred mli **)

open Types
include module type of Coord_utils
include module type of Coord_state



val get_agents_status : config ->
           [> `Assoc of
                (string *
                 [> `Int of int
                  | `List of
                      [> `Assoc of (string * Yojson.Safe.t) list ] list ])
                list ]
val register_capabilities : config -> agent_name:string -> capabilities:string list -> string
val update_agent_r : config ->
           agent_name:string ->
           ?status:string ->
           ?capabilities:string list -> unit -> string Types.masc_result
val find_agents_by_capability : config ->
           capability:string ->
           [> `Assoc of
                (string *
                 [> `Int of int
                  | `List of
                      [> `Assoc of
                           (string *
                            [> `List of [> `String of string ] list
                             | `String of string ])
                           list ]
                      list
                  | `String of string ])
                list ]
