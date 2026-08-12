(** Pure state transitions for MCP-session client identity ownership.

    The outer [Client_registry_eio] shell supplies time and newly materialized
    identities, then atomically swaps the returned immutable state. *)

type t

type install_outcome =
  | Registered of Client_identity.t
  | Reused of Client_identity.t

val empty : t

val reuse_session :
  now:float -> mcp_session_id:string -> t -> (t * Client_identity.t) option
(** Return and touch the identity already owned by [mcp_session_id]. A delayed
    caller cannot move [last_seen] behind a newer committed observation. A
    stale session mapping whose identity is absent is treated as a miss. *)

val install_session :
  now:float ->
  mcp_session_id:string ->
  candidate:Client_identity.t ->
  t ->
  t * install_outcome
(** Install [candidate] only if [mcp_session_id] is still unresolved. This
    second check makes an outer resolve-materialize-commit sequence race-safe. *)

val resolved_name : t -> string -> (string * bool) option

val cache_resolved_name :
  mcp_session_id:string ->
  name:string ->
  is_ephemeral:bool ->
  t ->
  t

val unregister_mcp_session : mcp_session_id:string -> t -> t
(** Remove one transport-session owner. Its identity is removed only after no
    remaining MCP session refers to the same identity session key. *)

val count : t -> int
