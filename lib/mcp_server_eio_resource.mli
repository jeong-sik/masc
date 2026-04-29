(** Mcp_server_eio_resource — \`resources/read\` JSON-RPC handler.

    Extracted from {!Mcp_server_eio} as part of the god-file
    decomposition.  Single external entry: {!handle_read_resource_eio}.

    Internal: re-exports of
    \[Mcp_transport_protocol.make_response\] /
    \[Mcp_transport_protocol.make_error\] (used to construct
    JSON-RPC envelopes inside the handler) and
    \[public_tool_help_schemas\] (delegate to {!Config.visible_tool_schemas})
    stay private — none have external callers. *)

val handle_read_resource_eio :
  Mcp_server.server_state ->
  Yojson.Safe.t ->
  Yojson.Safe.t option ->
  Yojson.Safe.t
(** [handle_read_resource_eio state id params] handles a
    [resources/read] JSON-RPC call.

    Parameter contract:
    - [state]: server state (provides config + session registry).
    - [id]: JSON-RPC request id (echoed in response).
    - [params]: optional JSON-RPC params object.  When [None] or
      not [`Assoc _], returns an error envelope with code [-32602]
      (the JSON-RPC 2.0 Invalid params code).

    Required fields in [params]:
    - [uri]: non-empty string.  Empty / missing produces error
      code [-32602] with message [Missing uri].

    The URI is parsed via {!Mcp_server.parse_masc_resource_uri}
    into a (resource_id, uri) pair, and the handler routes to the
    appropriate read source (messages directory, tool-help
    schemas, etc.) based on the resource id.

    Returns a JSON-RPC response envelope (jsonrpc / id / result or
    error fields).  Never raises — all error paths produce error
    envelopes via {!Mcp_transport_protocol.make_error}. *)
