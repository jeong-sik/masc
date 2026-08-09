(** Authenticated dashboard projection and operator resolution for the durable
    per-Keeper official-client session owner. *)

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
