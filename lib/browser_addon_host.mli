(** Public host admission for the installed browser Add-on. The caller supplies
    verified host authority; model arguments cannot select an installation.
    One handle retains the exact service and advertised tool across a workflow.
    Calls never retry or fall back to the core browser queue. *)
type t
val connect : config:Workspace.config -> access:Lane_addon_sources.access ->
  principal:Lane_addon_call_context.principal -> reserved:string list ->
  (t, Lane_addon_runtime.tool_call_error) result
(** [reserved] is the caller's complete host tool namespace, as in ordinary
    Add-on discovery. Visibility and name-collision checks remain authoritative. *)
val call : t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_runtime.tool_call_error) result
(** Uses the ordinary exported-tool path, including installation-selected
    middleware and host mediation. The original result and failure metadata
    are returned without rewriting or promoting a partial effect. *)
val error_result : start_time:Tool_timing.started -> Lane_addon_runtime.tool_call_error -> Tool_result.result
val snapshot : t -> (Yojson.Safe.t, Browser_addon_client.error) result
(** Read-only observation on the same original service. This is not a tool
    invocation and does not select, start or replace a browser. *)
type receipt = {binding:Browser_binding.t;data:Yojson.Safe.t;
  raw_result:Mcp_protocol.Mcp_types.tool_result}
(** The original successful MCP receipt remains available if a caller's
    observation projection or persistence fails after command completion. *)
val issue : ?required_actions:Browser_capabilities.operation list ->
  t -> preference:Browser_selection.preference -> Browser_lane.verb ->
  (receipt, Tool_result.result) result
(** Invoke the advertised tool once and decode its mandatory connection and
    success receipt. The selected schema hooks remain optional; identity and
    wire decoding remain mandatory. Failed/partial replies preserve raw data
    and effect metadata. Malformed post-dispatch replies have unknown effect. *)
