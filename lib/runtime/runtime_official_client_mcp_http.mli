(** Turn-scoped loopback MCP transport for official subscription clients.

    The listener binds only to IPv4 loopback on an ephemeral port, requires an
    independently generated Bearer capability, and is owned by the caller's
    Eio switch. Closing the turn switch closes the listener and all accepted
    connections. *)

type phase = Runtime_official_client_mcp.phase =
  | Awaiting_initialize
  | Awaiting_initialized
  | Ready

type snapshot =
  { phase : phase
  ; authenticated_requests : int
  ; rejected_requests : int
  ; tool_calls : int
  ; connection_failures : int
  ; last_connection_error : string option
  ; listener_failure : string option
  ; negotiated_protocol_version : string option
  }

type t

val start :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  server_name:string ->
  tool_specs:(unit -> Yojson.Safe.t list) ->
  call_tool:
    (name:string ->
     call_id:string ->
     arguments:Yojson.Safe.t ->
     Runtime_official_client_mcp.tool_result option) ->
  unit ->
  t

(** Exact remote-MCP configuration measured against Antigravity CLI 1.1.11.
    The returned JSON contains the ephemeral capability and must not be logged
    or persisted after the turn. *)
val mcp_config_json : t -> Yojson.Safe.t

val endpoint : t -> string
val snapshot : t -> snapshot
