(** Host-mediated machine calls. Published activity and credential policy belong here; emulator state
    stays in the worker. Other exported tools pass through unchanged. *)
val call :
  principal:Lane_addon_call_context.principal -> config:Workspace.config ->
  access:Lane_addon_sources.access -> reserved:string list ->
  export:Lane_addon_tool_export.t -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_runtime.tool_call_error) result

val call_shared :
  principal:Lane_addon_call_context.principal -> config:Workspace.config ->
  name:string -> arguments:Yojson.Safe.t ->
  (Mcp_protocol.Mcp_types.tool_result, Lane_addon_runtime.tool_call_error) result
(** Resolve a currently attached shared export, then revalidate its exact
    installation on invocation. The caller must already have authorized this
    tool and principal. This never grants access to Keeper-private exports. *)

val release_shared_controller :
  events:Machine_addon_events.batch -> config:Workspace.config -> holder:string -> by:string ->
  reason:Machine_controller_contract.holder_departure ->
  (Mcp_protocol.Mcp_types.tool_result option, Lane_addon_runtime.tool_call_error) result
(** Trusted lifecycle boundary only. The caller owns credential/lifecycle
    admission through this call; no credential lock is acquired here. [None]
    means no shared controller-capable installation exists. Returned notices
    must be published after credential admission ends. *)

val dos_event_batch : author:string -> Machine_addon_events.batch
(** Lifecycle caller owns readiness and draining after credential admission. *)
