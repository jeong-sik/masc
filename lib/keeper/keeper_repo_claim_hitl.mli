(** Keeper-side repository access projection for filesystem tools.

    [Keeper_repo_mapping] remains a pure policy/enforcement module and does
    not depend on keeper tool surfaces. This module is the composition layer
    that turns fail-closed repository denials into tool-facing responses.
    Keeper repository mappings are advisory/default-scope metadata and are not
    claimable access caps. *)

type access_result =
  | Access_allowed
  | Access_denied of string

val request_repository_access :
  keeper_id:string ->
  base_path:string ->
  repository_id:Repo_manager_types.repository_id ->
  access_result
(** Request access to a registered repository. Registered repositories are
    allowed even when outside the keeper's advisory/default mapping scope. Hard
    fail-closed cases return [Access_denied]. *)

val request_path_access :
  keeper_id:string -> base_path:string -> path:string -> access_result
(** Resolve [path] through the repository catalog and validate fail-closed
    repository identity/store cases. *)

val tool_response_json : path:string -> access_result -> Yojson.Safe.t
(** Render a tool-facing policy response for non-[Access_allowed] results. *)
