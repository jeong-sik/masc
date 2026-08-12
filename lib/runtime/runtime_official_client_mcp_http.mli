(** Turn-scoped loopback MCP transport for official subscription clients.

    The listener binds only to IPv4 loopback on an ephemeral port, requires an
    independently generated Bearer capability, and is owned by the caller's
    Eio switch. Closing the turn switch closes the listener and all accepted
    connections. *)

type t

type tool_response =
  { outcome : Runtime_official_client_mcp.tool_result
  ; after_response_sent : unit -> unit
  }
(** A completed tool outcome and the acknowledgement to run only after its
    HTTP response body has been written and flushed. *)

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
     tool_response option) ->
  unit ->
  t

(** Exact remote-MCP configuration measured against Antigravity CLI 1.1.11.
    The returned JSON contains the ephemeral capability and must not be logged
    or persisted after the turn. *)
val mcp_config_json : t -> Yojson.Safe.t

module For_testing : sig
  type snapshot =
    { phase : Runtime_official_client_mcp.phase
    ; authenticated_requests : int
    ; rejected_requests : int
    ; tool_calls : int
    ; connection_failures : int
    ; last_connection_error : string option
    ; listener_failure : string option
    ; negotiated_protocol_version : string option
    }

  val snapshot : t -> snapshot
end
