(** Mcp_server_eio_call_tool — [tools/call] handler with
    single dispatch and runtime-MCP keeper tracing.

    The .ml is intentionally kept behind this interface. External runtime
    callers reach {!handle_call_tool_eio}, the metric helpers, and the
    runtime-MCP keeper tracing surface declared below.

    The {!For_testing} module exposes a narrow pure helper for regression
    tests only.

    Internal helpers stay private at this boundary
    ([log_mcp_exn], [int_of_env_default],
    [classify_tool_failure_severity], [status_of_result],
    [structured_content_of_result],
    [nonempty_string_opt], [json_nonempty_string_opt],
    [runtime_mcp_keeper_error_preview],
    [runtime_mcp_keeper_tool_call_sse_payload],
    [runtime_mcp_masc_root],
    [record_runtime_mcp_trajectory_coverage_gap],
    [record_runtime_mcp_keeper_trajectory],
    [resolve_managed_agent_call]).

    [tool_profile] is referenced by {!handle_call_tool_eio}
    but the type itself is intentionally not re-exported
    here — external callers reach it via
    {!Mcp_server_eio_types.tool_profile} and the
    {!Mcp_server_eio_protocol} facade. *)

val record_mcp_server_operation_duration_sample :
  tool_name:string -> success:bool -> duration_seconds:float -> unit
(** Records one [mcp.server.operation.duration] sample for [tools/call].
    Used by the protocol layer for rejected calls that never enter
    {!handle_call_tool_eio}. Requires an active
    {!Otel_dispatch_hook.with_request_context}. *)

module For_testing : sig
  val activity_tool_called_payload :
    tool_name:string ->
    success:bool ->
    duration_ms:int ->
    source:string ->
    ?error_detail:string ->
    ?tool_args_preview:string ->
    Yojson.Safe.t ->
    Yojson.Safe.t

  val record_mcp_server_operation_duration :
    Tool_result.result -> duration_ms:int -> unit

  val record_mcp_server_operation_duration_sample :
    tool_name:string -> success:bool -> duration_seconds:float -> unit
end

(** {1 Runtime-MCP keeper trace context} *)

type keeper_runtime_mcp_log_context = {
  keeper_name : string;
  agent_name : string option;
  model : string;
  trace_id : string option;
  session_id : string option;
  generation : int option;
  turn : int option;
  keeper_turn_id : int option;
  task_id : string option;
  sandbox_profile : string option;
  sandbox_root : string option;
  allowed_paths : string list option;
  network_mode : string option;
  runtime_profile : string option;
}
(** Snapshot of the keeper-bound runtime-MCP context
    captured at tool-call time.  Threaded into telemetry +
    trajectory writers. *)

val runtime_mcp_keeper_log_context_of_entry :
  ?mcp_session_id:string ->
  Keeper_registry.registry_entry ->
  arguments:Yojson.Safe.t ->
  keeper_runtime_mcp_log_context
(** Builds a {!keeper_runtime_mcp_log_context} from a
    keeper registry entry.  [arguments] is inspected for
    embedded [agent_name] / [task_id] /
    [allowed_paths] overrides; the entry's
    [meta.runtime] supplies the rest. *)

val record_runtime_mcp_keeper_tool_trace :
  ?mcp_session_id:string ->
  Keeper_registry.registry_entry ->
  tool_name:string ->
  arguments:Yojson.Safe.t ->
  message:string ->
  success:bool ->
  duration_ms:int ->
  unit
(** Persists a single tool-call trace row for the keeper.
    Builds the {!keeper_runtime_mcp_log_context}
    internally (so callers do not need to pre-thread it),
    appends to the runtime-MCP trajectory log, emits the
    SSE payload, and bumps the trajectory-coverage
    counter.  Errors during persistence are swallowed
    with a [Log.Misc.warn] — telemetry must never abort
    the tool call. *)

(** {1 [tools/call] dispatcher} *)

val handle_call_tool_eio :
  execute_tool_eio:
    (sw:'sw ->
     clock:([> float Eio.Time.clock_ty ] as 'clk) Eio.Resource.t ->
     workspace_scope:Mcp_server.workspace_scope ->
     ?profile:Mcp_server_eio_types.tool_profile ->
     ?mcp_session_id:string ->
     ?auth_token:'auth ->
     ?internal_keeper_runtime:bool ->
     Mcp_server.server_state ->
     name:string ->
     arguments:Yojson.Safe.t ->
     Tool_result.result) ->
  maybe_emit_resource_notifications:
    (success:bool -> tool_name:string -> 'notify) ->
  broadcast_tools_list_changed:(unit -> unit) ->
  sw:'sw ->
  clock:'clk Eio.Resource.t ->
  ?profile:Mcp_server_eio_types.tool_profile ->
  ?mcp_session_id:string ->
  ?auth_token:'auth ->
  ?internal_keeper_runtime:bool ->
  Mcp_server.server_state ->
  Yojson.Safe.t ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** Handles a [tools/call] JSON-RPC request.

    [execute_tool_eio] is the inner dispatcher (passed in
    to break the cyclic dep with {!Tool_dispatch}).
    [maybe_emit_resource_notifications] is invoked after
    the call succeeds so the protocol layer can broadcast
    [resources/updated] for the resource ids the tool
    invalidated.  [broadcast_tools_list_changed] is fired
    when the call is known to alter the tool catalogue
    (long-running mutations, etc).

    The handler captures one immutable {!Mcp_server.workspace_scope} at
    admission.  The dispatcher and all post-execution workspace-scoped
    observations use that exact generation even when the tool changes the
    server's current workspace.  The dispatcher invokes the concrete tool
    exactly once, times that execution for telemetry, and on the
    keeper-runtime path threads
    {!record_runtime_mcp_keeper_tool_trace} into the
    success / failure branches.

    [sw] / [clock] type variables stay polymorphic so the
    protocol layer can call this function with whatever
    handle subset it has in scope (cycle 205 lesson —
    Eio handles inferred polymorphic when the .ml body
    only passes them through). *)
