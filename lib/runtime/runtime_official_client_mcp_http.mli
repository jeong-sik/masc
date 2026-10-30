(** Turn-scoped loopback MCP transport for official subscription clients.

    The listener binds only to IPv4 loopback on an ephemeral port, requires an
    independently generated Bearer capability, and is owned by the caller's
    Eio switch. Closing the turn switch closes the listener and all accepted
    connections. *)

type t

type tool_response =
  { outcome : Runtime_official_client_mcp.tool_result
  ; after_response_sent : unit -> unit
  ; stop : Runtime_official_client_tool.host_stop option
  }
(** A completed tool outcome. [stop] closes new admission immediately after
    the handler returns; previously reserved handlers still drain. The delivery
    observer runs only after the full HTTP response write succeeds. *)

val start :
  sw:Eio.Switch.t ->
  net:[ `Generic | `Unix ] Eio.Net.ty Eio.Resource.t ->
  secure_random:Eio.Flow.source_ty Eio.Resource.t ->
  server_name:string ->
  tool_specs:(unit -> Yojson.Safe.t list) ->
  tool_execution_mode:
    (name:string -> arguments:Yojson.Safe.t -> Agent_core.Tool_contract.execution_mode option) ->
  call_tool:
    (name:string ->
     call_id:string ->
     arguments:Yojson.Safe.t ->
     tool_response option) ->
  unit ->
  t
(** [tool_execution_mode] is the frozen producer contract for the exact tool
    and arguments and must return without yielding. [None] means no such admitted tool and prevents its handler
    from running. Concurrent calls may overlap; a Serial call waits for all
    preceding calls and fences later calls until actual handler settlement.
    Protocol validation and schedule reservation keep request admission order,
    while no dispatch mutex is held over a tool handler or predecessor wait.
    Cancelling a queued Serial call preserves its predecessors for followers;
    it never releases their effect boundary early. *)

type endpoint =
  { url : string
    (** The loopback URL. Its path carries a per-turn random id. *)
  ; headers : (string * string) list
    (** The [Authorization] header with the per-turn Bearer token. *)
  }
(** Where a client reaches this bridge and how it authenticates. Both fields
    carry the turn's capability: anyone holding them can call every tool the
    bridge serves until the owning switch closes. Never log or persist this
    value; pass it only to the client process the turn spawns. *)

val await_host_stop : t -> Runtime_official_client_tool.host_stop
(** Wait until a stop-request response reaches its complete-write or failed-write
    boundary, then drain every previously admitted handler reservation. Admission
    closes when the first handler returns a stop; queued admitted work still runs.
    New calls receive an explicit no-execution outcome. A later terminal failure
    outranks an earlier successful/deferred stop. Waiting holds no dispatch lock.
    A failed-write boundary never certifies response delivery or consumption. *)

val endpoint : t -> endpoint
(** The single source of the bridge's URL and header. {!mcp_config_json}
    builds from it, and so does a client that takes its MCP servers as typed
    values (Muse Code's [session/start]). *)

(** Remote-MCP configuration for Antigravity CLI: [url] and [headers] as
    measured against 1.1.11, [tools] as measured against 1.2.9. The returned
    JSON carries {!endpoint}, so it contains the ephemeral capability and must
    not be logged or persisted after the turn.

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
    ; retained_tool_reservations : int
        (** Exact unresolved admitted requests; no completed history is retained. *)
    }

  val snapshot : t -> snapshot
end
