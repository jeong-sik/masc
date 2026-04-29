(** Mcp_server_eio_execute — inner [tools/call] dispatcher
    plus the join-state resolver shared with the keeper
    onboarding path.

    The .ml is 919 lines.  Only 4 entries reach callers:
    - {!resolve_join_state} and
      {!should_read_legacy_persisted_agent_name} —
      [test/test_mcp_server_eio.ml] exercises both to
      verify the join-required + ephemeral-name fallback
      decisions stay consistent across refactors.
    - {!execute_tool_eio} — invoked by
      [lib/server/server_runtime_bootstrap.ml] and threaded
      through {!Mcp_server_eio_call_tool.handle_call_tool_eio}
      as its [~execute_tool_eio] callback.
    - {!wait_for_message_eio} — re-exposed because
      [lib/mcp_server_eio.ml] does
      [include Mcp_server_eio_execute] and reaches it
      unqualified.

    Internal helpers stay private at this boundary
    ([log_mcp_exn] re-export, [is_ephemeral_agent_name],
    [is_transient_agent_name],
    [silent_auth_token_error_kind],
    [direct_call_block_message]).  The [execute_tool_eio]
    body itself contains many internal sub-helpers
    (audit wrappers, tool dispatchers, error formatters)
    that are local to its lexical scope. *)

(** {1 Join state resolution} *)

val resolve_join_state :
  room_initialized:bool ->
  join_required:bool ->
  agent_name:string ->
  base_path:string ->
  check_join:(string -> bool) ->
  bool
(** Returns [true] iff the request should be treated as a
    joined-agent call.

    The decision is short-circuited:
    - [room_initialized = false] or [join_required = false]
      → [false] (no join check needed).
    - [agent_name = "unknown"] → [false] (sentinel name).
    - Otherwise probes [check_join agent_name]; on miss,
      tries an alias chain via [is_ephemeral_agent_name]
      and the [base_path]-derived persisted name lookup.

    [check_join] is injected so tests can drive the
    resolver against a deterministic registry. *)

(** {1 Legacy ephemeral fallback} *)

val should_read_legacy_persisted_agent_name :
  has_explicit_agent_name:bool ->
  agent_name:string ->
  bool
(** Returns [true] when the dispatcher should attempt to
    recover an agent_name from the legacy persisted
    sidecar (used by the operator surface during the
    transition off the persisted name file).

    Triggers iff the request did not pass [agent_name]
    explicitly AND the resolved [agent_name] is in the
    {b ephemeral} class ([_ephemeral_*] / unknown
    sentinels).  Tested directly to keep the legacy /
    explicit path split honest. *)

(** {1 [tools/call] inner dispatcher} *)

val execute_tool_eio :
  sw:Eio.Switch.t ->
  clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?profile:Mcp_server_eio_types.tool_profile ->
  ?mcp_session_id:string ->
  ?auth_token:string ->
  ?internal_keeper_runtime:bool ->
  Mcp_server.server_state ->
  name:string ->
  arguments:Yojson.Safe.t ->
  bool * string
(** Routes [(name, arguments)] to the matching tool tag
    via {!Tool_dispatch.lookup_tag} and runs the handler.
    Returns [(success, message)] where [message] is a
    JSON-encoded response body (the wrapper layer
    {!Mcp_server_eio_call_tool.handle_call_tool_eio}
    composes the final JSON-RPC envelope around it).

    Side effects on the request scope:
    - Refreshes [Eio_context.set_switch] / [set_clock] so
      downstream helpers that still consult ambient
      handles see the current request scope (tests can
      otherwise leave a finished switch in the global slot).
    - Bumps the [Prometheus.record_request] counter for
      every inbound call.

    [profile] defaults to [Full]; [internal_keeper_runtime]
    defaults to [false] (set [true] for keeper-runtime
    callers that bypass the public-tool whitelist).

    Type variables [{'sw, 'clk, 'auth}] stay polymorphic
    (cycle 205 lesson) so the dispatcher's body — which
    only passes them through to internal helpers — does
    not over-constrain the caller chain. *)

(** {1 Cascade re-exports} *)

val wait_for_message_eio :
  clock:_ Eio.Time.clock ->
  Session.registry ->
  agent_name:string ->
  timeout:float ->
  Yojson.Safe.t option
(** Re-export of {!Mcp_server_eio_helpers.wait_for_message_eio}.
    Pinned at this boundary because
    [lib/mcp_server_eio.ml] does
    [include Mcp_server_eio_execute] and reaches the
    helper unqualified.  Source-of-truth lives in
    {!Mcp_server_eio_helpers}. *)
