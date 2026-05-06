(** Mcp_server_eio_call_tool — [tools/call] handler with
    timeout, read-only retry, runtime-MCP keeper tracing.

    The .ml is 959 lines.  External callers reach exactly
    six symbols — {!handle_call_tool_eio} (the dispatcher
    entry point invoked from
    {!Mcp_server_eio_protocol.handle_request}),
    {!contains_casefold} (re-used by the protocol layer
    for log-line classification), and four runtime-MCP
    keeper tracing helpers ({!quality_from_result},
    {!record_runtime_mcp_keeper_tool_trace},
    {!runtime_mcp_keeper_log_context_of_entry},
    {!tool_timeout_sec_opt}).

    Internal helpers stay private at this boundary
    ([log_mcp_exn], [int_of_env_default],
    [classify_tool_failure_severity],
    [parse_status_from_message], [quality_issue],
    [nonempty_string_opt], [json_nonempty_string_opt],
    [runtime_mcp_tool_surface_class],
    [runtime_mcp_keeper_error_preview],
    [runtime_mcp_keeper_tool_call_sse_payload],
    [runtime_mcp_masc_root],
    [record_runtime_mcp_trajectory_coverage_gap],
    [record_runtime_mcp_keeper_trajectory],
    [read_only_retry_limit], [is_retryable_message],
    [read_only_retry_wait], [call_tool_with_readonly_retry],
    [coerce_tool_timeout_sec],
    [resolve_managed_agent_call]).

    [tool_profile] is referenced by {!handle_call_tool_eio}
    but the type itself is intentionally not re-exported
    here — external callers reach it via
    {!Mcp_server_eio_types.tool_profile} and the
    {!Mcp_server_eio_protocol} facade. *)

(** {1 Casefold substring search} *)

val contains_casefold : string -> string -> bool
(** [contains_casefold haystack needle] — true iff
    [needle] occurs in [haystack] under
    [String_util.contains_substring_ci] (case-insensitive).
    Empty needle returns [true].  Pinned because the
    protocol layer's tool-call log path
    ({!Mcp_server_eio_protocol.mcp_tool_call_log_details})
    re-uses it for outcome classification. *)

(** {1 Quality JSON} *)

val quality_from_result :
  success:bool ->
  message:string ->
  attempts:int ->
  Yojson.Safe.t
(** Builds the [quality] envelope attached to a tool-call
    response.  On success returns
    [`Assoc [("passed", `Bool true); ("issues", `List [])]].
    On failure classifies [message] (timeout / cancellation
    / generic) and emits a single issue entry with
    [severity], [code], [message], [attempts]. *)

(** {1 Per-tool timeout} *)

val tool_timeout_sec_opt :
  tool_name:string ->
  _arguments:Yojson.Safe.t ->
  float option
(** Returns the timeout (seconds) the dispatcher should
    apply to the call, [None] for tools that opt out
    (e.g. [masc_keeper_msg], which gates on its own
    [max_turns] / [max_cost_usd]). Board write tools use
    [MASC_TOOL_TIMEOUT_BOARD_SEC] (default 90s, clamped
    5s..300s). This includes keeper/masc board post/comment/vote,
    comment_vote, delete, cleanup, curation_submit, and
    [masc_board_reaction]. [masc_persona_generate] uses a fixed
    outer timeout above its internal OAS worker budget. Other bounded tools use
    [MASC_TOOL_TIMEOUT_DEFAULT_SEC] (default 60s, same
    clamp). [_arguments] is accepted for parity with future
    per-arg overrides but currently unused. *)

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
  goal_ids : string list option;
  sandbox_profile : string option;
  sandbox_root : string option;
  allowed_paths : string list option;
  network_mode : string option;
  approval_mode : string option;
  tool_surface_class : string option;
  visible_tool_count : int option;
  required_tools : string list option;
  missing_required_tools : string list option;
  cascade_profile : string option;
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
    embedded [agent_name] / [task_id] / [goal_ids] /
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
     ?profile:Mcp_server_eio_types.tool_profile ->
     ?mcp_session_id:string ->
     ?auth_token:'auth ->
     ?internal_keeper_runtime:bool ->
     Mcp_server.server_state ->
     name:string ->
     arguments:Yojson.Safe.t ->
     bool * string) ->
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
    (autoresearch start / stop, etc).

    The dispatcher applies the per-tool timeout from
    {!tool_timeout_sec_opt}, retries read-only failures
    (subject to [Env_config.Tools.readonly_retry_limit]),
    times the execution for telemetry, and on the
    keeper-runtime path threads
    {!record_runtime_mcp_keeper_tool_trace} into the
    success / failure branches.

    [sw] / [clock] type variables stay polymorphic so the
    protocol layer can call this function with whatever
    handle subset it has in scope (cycle 205 lesson —
    Eio handles inferred polymorphic when the .ml body
    only passes them through). *)
