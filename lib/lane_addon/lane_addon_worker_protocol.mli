(** MCP admission and tool contracts, independent of the worker's execution
    engine. This module never creates, owns or proves cleanup of a process or
    container. The execution owner must revoke admission before cleanup. *)
type error = Invalid_contract of string | Protocol_failed of string
  | Host_refusal of Lane_addon_call_context.host_refusal
  | Invalid_observation of string | Stopped
type contract = private {
  action_tool : string option;
  tool_invocation : Lane_addon_types.tool_invocation;
  exported_tools : string list;
  tool_hooks : Lane_addon_types.tool_hook list;
  max_reply_bytes : int;
}
val contract : action_tool:string option ->
  tool_invocation:Lane_addon_types.tool_invocation -> exported_tools:string list ->
  tool_hooks:Lane_addon_types.tool_hook list -> max_reply_bytes:int ->
  (contract, error) result
val contract_of_package : Lane_addon_types.package -> (contract, error) result
type t
val create : instance_id:string -> contract:contract ->
  ?artifact_store:Lane_addon_store.t -> ?sampling_broker:Lane_addon_sampling.t ->
  unit -> t
(** Caller-admitted instance identity. A supplied observation sampling broker
    must already have been checked for this exact package/instance by its host
    factory. The owner connects with the contract's transport byte limit. *)
val initialize : t -> Agent_core.Mcp.t -> (unit, error) result
(** Takes the exact connection before initialization/discovery. A concurrent
    revoke refuses publication, even if initialization later returns. A second
    connection is refused without replacing the first; its caller still owns it.
    If revoked before its first connection, the first arriving connection is
    consumed and closed. Failed/cancelled discovery permanently revokes admission.
    Schema, exports and hooks become visible together only in Ready. *)
val revoked : t -> bool
val revoke : t -> unit
val close : t -> unit
(** Revoke and close this MCP connection. This says nothing about executor
    cleanup, child processes, profiles or resource release. *)
val exported_tools : t -> Mcp_protocol.Mcp_types.tool list
val action_schema : t -> Yojson.Safe.t option
val observe : t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  (Lane_addon_types.output, error) result
val act : t -> arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, error) result
val call_exported_tool : ?on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) ->
  ?authorize:Lane_addon_call_context.mediation ->
  ?principal:Lane_addon_call_context.principal -> t -> name:string ->
  arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) result
(** Call the target through its exact initialized contract, without replay.
    Raw replies are captured before selected output validation. Cancellation
    revokes admission and propagates to the execution owner. *)
