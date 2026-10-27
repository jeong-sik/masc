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
  host_requests : bool;
}
val contract : action_tool:string option ->
  tool_invocation:Lane_addon_types.tool_invocation -> exported_tools:string list ->
  tool_hooks:Lane_addon_types.tool_hook list -> max_reply_bytes:int ->
  host_requests:bool ->
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
type operator_error = Operator_unavailable | Operator_rejected | Operator_outcome_unknown
val operator_schema : t -> Yojson.Safe.t option
val companion_tools : t -> string list
(** Ready-only negotiated export names. The optional version-2 handshake requires
    host context and supports binding after a validated public reply. No grant
    is given to other tools; unsupported hosts cannot silently negotiate it. *)
val observation_effect : t -> string -> Lane_addon_call_context.observation_effect
(** What the Ready worker declared on its {!Lane_addon_call_context.effects_tool}
    port for this export. An export it left out, a missing or unsupported port
    marker, a package that declares that name as an action or export, or a
    worker that is not Ready is [May_change]. MCP [readOnlyHint] never decides
    this. *)
val call_operator : t -> admit:(unit -> (unit, operator_error) result) ->
  arguments:Yojson.Safe.t -> (Yojson.Safe.t, operator_error) result
(** Private [lane_operator] port. Only the authenticated operator HTTP boundary
    may call it. This bypasses model exports, hooks, result callbacks, receipts
    and observation retention. Errors never contain worker/request text.
    Discovery is optional, exact and atomic with Ready. A lost reply is never
    replayed. Cancellation revokes the original connection. [admit] rechecks
    original host authority under the per-worker RPC mutex, just before send;
    the host must not hold global lifecycle locks while waiting for the reply. *)
val host_requests : t -> (Yojson.Safe.t, error) result
val host_result : t -> arguments:Yojson.Safe.t -> (Yojson.Safe.t, error) result
(** Private host request/result ports. Both must be advertised exactly once
    before a model-capable contract becomes Ready. They cannot be exported as
    model-facing tools or called through a contract that disabled them. *)
val observe : t -> binding:Yojson.Safe.t -> sources:Yojson.Safe.t ->
  (Lane_addon_types.output, error) result
val act : t -> arguments:Yojson.Safe.t -> (Lane_addon_action.package_result, error) result
type result_finalizer = name:string -> arguments:Yojson.Safe.t ->
  principal:Lane_addon_call_context.principal -> result:Mcp_protocol.Mcp_types.tool_result ->
  (Mcp_protocol.Mcp_types.tool_result, string) result
(** Mandatory host receipt processing when supplied. Companion replies are
    validated and projected to public content before this callback. *)
type companion_admission = { context:Lane_addon_call_context.companion; admit:unit -> bool }
(** Host callback is rechecked under the original worker RPC mutex immediately
    before dispatch. It must not acquire global configuration/action locks. *)
val call_exported_tool : ?on_result:(Mcp_protocol.Mcp_types.tool_result -> unit) ->
  ?on_dispatch:(unit -> unit) ->
  ?companion:companion_admission ->
  ?finalize_result:result_finalizer ->
  ?authorize:Lane_addon_call_context.mediation ->
  ?principal:Lane_addon_call_context.principal -> t -> name:string ->
  arguments:Yojson.Safe.t -> (Mcp_protocol.Mcp_types.tool_result, error) result
(** Call the target through its exact initialized contract, without replay.
    [on_dispatch] runs under the RPC mutex right before each RPC of this call is
    written; a call that never ran it reached nothing in the worker, and its
    cancellation leaves the protocol serving. A call cancelled after it wrote
    revokes the protocol. A mediated call counts as written from its first
    RPC, the controller snapshot included, so one cancelled while its next
    RPC waits for the mutex also revokes: more than needed, never less.
    Ordinary [on_result] sees each original RPC reply under the RPC mutex.
    Companion callbacks see only the validated public projection, with worker
    text and metadata removed. Companion exports require closed output schemas.
    After invocation succeeds, [finalize_result] runs once outside that mutex;
    ordinary calls preserve their existing finalization-before-validation order.
    Finalization errors are post-dispatch protocol failures, never replayed.
    Cancellation always propagates to the execution owner. *)
