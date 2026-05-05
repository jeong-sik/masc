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

(** Encode the workspace source tag as the [X-Workspace-Source] header
    so the frontend can render hints (e.g. "Playground 없음 — 프로젝트로
    fallback") without parsing the JSON body. Exposed for unit
    testing. *)
val source_header :
  [ `Project
  | `Playground of string
  | `PlaygroundMissing of string
  | `KeeperUnknown of string ] ->
  (string * string) list
