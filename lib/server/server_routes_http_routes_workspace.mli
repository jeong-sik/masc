module Http = Http_server_eio

val add_routes : Http.Router.t -> Http.Router.t

(** Pure dispatch logic for the [?keeper=<name>] query param. Exposed
    for unit testing — production code goes through {!add_routes}. *)
val classify_keeper_query :
  project_base:string ->
  lookup_playground:(string -> string option) ->
  exists_dir:(string -> bool) ->
  string option ->
  string * [ `Project
           | `Playground of string
           | `PlaygroundMissing of string
           | `KeeperUnknown of string ]
