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

(** Remote-MCP configuration for Antigravity CLI: [url] and [headers] as
    measured against 1.1.11, [tools] as measured against 1.2.9. The returned
    JSON contains the ephemeral capability and must not be logged or persisted
    after the turn.

    [eager_tools] are declared [tools.<name>.eager = true]. Antigravity lists
    a tool without that declaration by name only and tells the model to read
    its schema file before calling it through [call_mcp_tool]. A masc home
    denies [read_file] outright ([Runtime_antigravity_home.settings_json]),
    and a rule scoped to the schema folder is overridden by that deny, so such
    a tool is called blind. An eager tool is registered with its schema
    instead (agy 1.2.9, measured 2026-09-24). Pass every tool the bridge
    serves. *)
val mcp_config_json : t -> eager_tools:string list -> Yojson.Safe.t

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
