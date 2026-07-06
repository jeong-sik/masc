(** Keeper-side HITL bridge for repository-scope claim requests.

    [Keeper_repo_mapping] remains a pure policy/enforcement module and does
    not depend on the keeper approval queue. This module is the composition
    layer that turns a claimable selected-scope denial into a non-blocking HITL
    request and applies the mapping mutation only after operator approval. *)

type access_result =
  | Access_allowed
  | Access_pending_approval of
      { approval_id : string
      ; repository_id : Repo_manager_types.repository_id
      }
  | Access_denied of string

val repository_claim_tool_name : string
val repository_claim_request_type : string

val request_repository_access :
  keeper_id:string ->
  base_path:string ->
  repository_id:Repo_manager_types.repository_id ->
  access_result
(** Request access to a registered repository. Returns
    [Access_pending_approval] only for the selected-scope miss that an operator
    can resolve by adding [repository_id] to the keeper mapping. Hard
    fail-closed cases return [Access_denied]. *)

val request_path_access :
  keeper_id:string -> base_path:string -> path:string -> access_result
(** Resolve [path] through the repository catalog and request HITL access for
    claimable repository-scope misses. *)

val tool_response_json : path:string -> access_result -> Yojson.Safe.t
(** Render a tool-facing policy response for non-[Access_allowed] results. *)
