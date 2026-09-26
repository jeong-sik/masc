(** Authenticated dashboard projection and operator resolution for the durable
    per-Keeper official-client session owner.

    The session wire field [session_binding_sha256] identifies the durable
    account, client tool posture, and descriptor binding. It is separate from
    the pure effective-tool-surface projection [tool_surface_sha256]. *)

type error_kind =
  | Bad_request
  | Conflict
  | Service_unavailable

type error =
  { kind : error_kind
  ; code : string
  ; message : string
  }

val snapshot :
  base_path:string ->
  keeper_name:string ->
  (Yojson.Safe.t, error) result

val resolve_body :
  config:Workspace.config ->
  actor:string ->
  body:string ->
  (Yojson.Safe.t, error) result
