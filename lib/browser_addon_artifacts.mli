(** Mandatory host artifact completion for ordinary browser exports. Independent
    of selected input/output validation and all LLM Exact Output consumers. *)
val finalize : socket:Browser_addon_socket.t -> client:Browser_addon_client.t ->
  store:Tool_blob_store.t -> name:string -> arguments:Yojson.Safe.t ->
  principal:Lane_addon_call_context.principal -> result:Mcp_protocol.Mcp_types.tool_result ->
  (Mcp_protocol.Mcp_types.tool_result, string) result
(** Runs after the original invocation, outside the MCP RPC mutex and before
    selected output validation. Original identity, metadata and raw receipt
    provenance are retained. No command or transfer is replayed. *)
