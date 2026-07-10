(** Keeper-side repository access projection for filesystem tools.

    [Keeper_repo_mapping] remains a pure policy/enforcement module and does
    not depend on keeper tool surfaces. This module is the composition layer
    that turns fail-closed repository denials into tool-facing responses and
    non-blocking operator registration requests when a sandbox clone provides
    enough structured evidence.
    Keeper repository mappings are advisory/default-scope metadata and are not
    claimable access caps. *)

type access_result =
  | Access_allowed
  | Access_denied of string
  | Access_denied_hitl_pending of { detail : string; approval_id : string }

type registration_restore_outcome =
  | No_registration_record
  | Registration_restored
  | Registration_superseded
  | Registration_corrupt of string

val request_repository_access :
  keeper_id:string ->
  base_path:string ->
  repository_id:Repo_manager_types.repository_id ->
  access_result
(** Request access to a registered repository. Registered repositories are
    allowed even when outside the keeper's advisory/default mapping scope. Hard
    fail-closed cases return [Access_denied]. When [repository_id] is not
    registered but the keeper already has a verifiable sandbox clone with the
    same repository component, this durably pauses the keeper and queues a
    Blocking operator repository-registration request instead of silently
    collapsing to a terminal denial. *)

val restore_pending_registration_hitl :
  config:Workspace.config ->
  Keeper_meta_contract.keeper_meta ->
  registration_restore_outcome
(** Restore a callback-owned Blocking repository approval from its typed
    durable operation record. The typed outcome distinguishes absence, an
    installed/replayed gate, supersession by newer keeper state, and corrupt
    durable state requiring operator repair. *)

val request_path_access :
  keeper_id:string -> base_path:string -> path:string -> access_result
(** Resolve [path] through the repository catalog and validate fail-closed
    repository identity/store cases. *)

val tool_response_json : path:string -> access_result -> Yojson.Safe.t
(** Render a tool-facing policy response for non-[Access_allowed] results. *)
