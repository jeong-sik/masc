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

(** Pure dispatch logic for repository-aware workspace queries.
    [repo_param] takes precedence over [keeper_param], matching the
    dashboard IDE repository picker. *)
val classify_workspace_query :
  project_base:string ->
  lookup_repository:(string -> string option) ->
  lookup_playground:(string -> string option) ->
  exists_dir:(string -> bool) ->
  repo_param:string option ->
  keeper_param:string option ->
  string * [ `Project
           | `Repository of string
           | `RepositoryMissing of string
           | `RepositoryUnknown of string
           | `Playground of string
           | `PlaygroundMissing of string
           | `KeeperUnknown of string ]

(** Encode the workspace source tag as the [X-Workspace-Source] header
    so the frontend can render hints (e.g. "Playground 없음 — 프로젝트로
    fallback") without parsing the JSON body. Exposed for unit
    testing. *)
val source_header :
  [ `Project
  | `Repository of string
  | `RepositoryMissing of string
  | `RepositoryUnknown of string
  | `Playground of string
  | `PlaygroundMissing of string
  | `KeeperUnknown of string ] ->
  (string * string) list

(** [rel_under base safe] returns the path of [safe] relative to [base],
    handling [base = "/"], trailing slashes, and the [safe = base] case
    (returns [""]). Caller must have already enforced the prefix
    invariant via the internal [safe_path] helper. Exposed for unit
    testing. *)
val rel_under : string -> string -> string

(** [valid_git_ref s] is [true] iff [s] is a non-empty, ≤256-char string
    drawn from the conservative ref/SHA charset and not starting with
    ["-"]. Used to refuse query-string values that could be parsed as
    git options (e.g. [?base_ref=-L1,9999]). Exposed for unit testing. *)
val valid_git_ref : string -> bool
