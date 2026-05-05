(** Worker_container_types — local-worker run shapes and the
    JSON-RPC bridge to the embedded MASC tool surface.

    Splits cleanly into three concerns:
    - {!run_result} / {!worker_container_meta} / {!tool_exec_result}
      types: the values flowing between {!Worker_runtime},
      {!Worker_oas}, and {!Worker_runtime_helper_protocol}.
    - The MCP transport bridge ({!call_masc_tool},
      {!join_worker}, {!leave_worker}, {!mcp_endpoint_url}):
      a JSON-RPC client that lets a local worker call MASC
      tools without going through the HTTP server's auth
      machinery.
    - Usage / cost helpers ({!merge_usage}) plus the env-var
      reader convenience wrappers
      ({!local_worker_max_tokens},
      {!local_worker_heartbeat_interval_sec}).

    The .ml has ~38 toplevels but external callers reach only
    the 15 entries below.  Internal helpers
    ([next_jsonrpc_id], [strip_mcp_prefix],
    [has_agent_name_field], [inject_default_agent_name],
    [extract_prompt_block], [masc_http_base_url],
    [request_id_matches], [normalize_mcp_body],
    [extract_tool_text], [extract_jsonrpc_error],
    [post_json_via_eio], [call_jsonrpc],
    [tool_schema_of_name], [tool_defs_of_schemas],
    [followup_prompt], [split_top_level],
    [find_top_level_char], [parse_text_tool_args],
    [parse_text_tool_calls], [make_usage],
    [estimate_cost_usd], [worker_session_id],
    [worker_auth_token]) stay private.

    {!Worker_container} does [include Worker_container_types]
    and reaches a few additional helpers unqualified
    ({!list_masc_tools}, {!inject_default_agent_name},
    {!safe_text_for_followup}); those are pinned below at the
    boundary the include cascade actually consumes. *)

(** {1 Worker run / meta types} *)

type tool_exec_result = {
  text : string;
  is_error : bool;
}
(** Outcome of a single MCP [tools/call] invocation: the
    text payload returned by the tool plus the [isError] flag
    extracted from the JSON-RPC envelope. *)

type run_result = {
  output : string;
  model_used : string;
  input_tokens : int option;
  output_tokens : int option;
  cost_usd : float option;
  tool_call_count : int;
  tool_names : string list;
  session_id : string;
  raw_trace_run : Agent_sdk.Raw_trace.run_ref option;
  api_response : Agent_sdk.Types.api_response option;
  proof : Agent_sdk.Cdal_proof.t option;
}
(** Summary of a finished worker run: aggregated text
    [output], the model id that handled the run,
    accumulated token / cost / tool-call counters, and the
    optional OAS artifacts ([raw_trace_run], [api_response],
    [proof]) attached when the worker ran through the OAS
    SDK path.  Consumed by {!Worker_oas},
    {!Worker_runtime_helper_protocol}, and the run-result
    serializer. *)

type worker_container_state =
  | Worker_missing
  | Worker_pending
  | Worker_ready
(** Lifecycle state of a per-worker container.  [Worker_pending]
    is the transient "spawning / loading" stage; [Worker_ready]
    means the worker has registered with MASC and accepted the
    first heartbeat. *)

type worker_container_meta = {
  version : int;
  worker_name : string;
  mcp_session_id : string;
  workspace_path : string;
  role : string option;
  selection_note : string option;
  runtime_backend : Worker_execution_backend.t;
  thinking_enabled : bool option;
  timeout_seconds : int option;
  effective_model : string;
  checkpoint_path : string;
  turn_log_path : string;
  last_run_at : float option;
}
(** Per-worker metadata persisted alongside the checkpoint
    file.  [version] is {!worker_container_version} at write
    time so older readers can detect format drift.
    [runtime_backend] selects the local execution backend
    (docker / process / mock).  [last_run_at] is updated on
    every completed turn so the heartbeat loop can detect a
    stalled worker. *)

(** {1 Constants} *)

val worker_container_version : int
(** Schema version for {!worker_container_meta}.  Bumped on
    breaking changes; consumers compare against this value
    before deserializing a checkpoint. *)

(** {1 Local-worker env-var convenience} *)

val local_worker_max_tokens : unit -> int
(** Cached read of [Env_config.Worker.local_worker_max_tokens].
    Convenience wrapper so call sites do not need to import
    [Env_config.Worker] just for this value. *)

val local_worker_heartbeat_interval_sec : unit -> int
(** Cached read of [Env_config.Worker.local_worker_heartbeat_sec].
    Heartbeat cadence (seconds) used by the local-worker
    runtime to keep its MASC session alive. *)

(** {1 JSON utilities re-exported for callers} *)

val unique_preserve_order : 'a list -> 'a list
(** Order-preserving deduplication.  Pinned alias of
    {!Json_util.dedupe_keep_order} kept here so callers that
    historically reached it via [Worker_container_types]
    continue to work without import churn.  Source-of-truth
    is in {!Json_util}. *)

(** {1 Usage / cost helpers} *)

val merge_usage :
  Agent_sdk.Types.api_usage -> Agent_sdk.Types.api_usage -> Agent_sdk.Types.api_usage
(** Sum two usage records field-wise: [input_tokens],
    [output_tokens], [cache_creation_input_tokens],
    [cache_read_input_tokens], and [cost_usd] (sum if both
    sides have it; pass through the side that does; [None]
    if neither). *)

(** {1 MCP / MASC transport URL} *)

val mcp_endpoint_url : auth_token:string option -> string
(** Resolves the MCP HTTP endpoint URL the local worker
    should call.  The [auth_token] is currently consulted
    only to decide whether to route through the
    authenticated path (the URL itself is the same; the
    parameter is preserved so future routing changes can
    branch on it without API churn). *)

(** {1 MASC tool client} *)

val call_masc_tool :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  tool_name:string ->
  args:Yojson.Safe.t ->
  (tool_exec_result, string) result
(** Invokes a MASC tool via JSON-RPC [tools/call].
    Auto-injects the [token] argument when [auth_token] is
    present and the args object lacks one (mirrors the same
    convenience as the public HTTP path).  Returns the
    extracted text and [isError] flag, or an error string on
    transport / parse / RPC failure.  Re-raises
    [Eio.Cancel.Cancelled]. *)

val join_worker :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  worker_name:string ->
  (tool_exec_result, string) result
(** Convenience wrapper around {!call_masc_tool} for the
    [masc_join] tool.  Passes the canonical capability set
    ([llama], [mcp-worker], [local-tool-loop]) so the room
    routing knows this is a local worker, not a coordinating
    keeper. *)

val leave_worker :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  worker_name:string ->
  (tool_exec_result, string) result
(** Convenience wrapper around {!call_masc_tool} for the
    [masc_leave] tool.  Pairs with {!join_worker} on worker
    shutdown to retire the agent registration. *)

(** {1 Default system prompt} *)

val default_system_prompt :
  worker_name:string ->
  model_id:string ->
  ?role:string ->
  ?selection_note:string ->
  unit ->
  string
(** Builds the canonical system prompt seeded into a freshly
    spawned local worker.  [role] and [selection_note] are
    optional contextual hints (the leader-selected model
    note, the assigned coord role) — both empty strings are
    treated as missing. *)

(** {1 Helpers reached through [include Worker_container_types]} *)

val list_masc_tools :
  sw:Eio.Switch.t ->
  auth_token:string option ->
  session_id:string ->
  ?names:string list option ->
  unit ->
  (Masc_domain.tool_schema list, string) result
(** Lists the MASC tool schemas visible to a local worker.
    [sw], [auth_token], and [session_id] are accepted for
    parity with {!call_masc_tool} but currently unused — the
    schema list is sourced directly from
    [Agent_tool_surfaces.local_worker_tool_schemas].
    [names] optionally restricts the set returned. *)

val inject_default_agent_name :
  worker_name:string ->
  schema:Masc_domain.tool_schema option ->
  Yojson.Safe.t ->
  Yojson.Safe.t
(** When [schema] declares an [agent_name] property and the
    args object lacks one, prepends [agent_name = worker_name]
    to it.  Otherwise returns the args unchanged.  Used by
    {!Worker_container} to honour the runtime contract that
    promises an injected [agent_name] when the schema
    requires it. *)

val safe_text_for_followup : string -> string
(** Trims and length-caps a free-form text fragment for
    inclusion in a follow-up prompt.  Keeps the first 1200
    bytes after [String.trim] and appends ["...[truncated]"]
    when the input is longer.  Never raises. *)

val parse_text_tool_calls :
  string -> Agent_sdk.Types.content_block list
(** [parse_text_tool_calls content] extracts inline
    [mcp__masc__*(...)] tool-call invocations from a free-form
    text fragment and returns them as [Agent_sdk.Types.ToolUse]
    content blocks.  Returns [\[\]] when no invocations are
    found.  Pinned for behaviour-tests under
    {!test/test_worker_container_coverage} — used by the local
    worker runtime to recover tool calls embedded in model
    text output. *)

val worker_auth_token :
  base_path:string ->
  worker_name:string ->
  (string option, string) result
(** Resolves the auth token a local worker should use when
    calling MASC tools.  Reads the auth config under
    [base_path]; if auth is disabled or tokens are not
    required, returns [Ok None] so the worker runs
    unauthenticated.  Otherwise mints a fresh token via
    {!Auth.create_token} with the [Worker] role and returns
    [Ok (Some token)].  Auth errors are converted to a
    string via {!Masc_domain.masc_error_to_string}. *)
(** Builds the canonical system prompt seeded into a freshly
    spawned local worker.  [role] and [selection_note] are
    optional contextual hints (the leader-selected model
    note, the assigned coord role) — both empty strings are
    treated as missing. *)
