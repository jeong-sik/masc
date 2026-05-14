(** Mcp_server_eio_execute — inner [tools/call] dispatcher
    plus the join-state resolver shared with the keeper
    onboarding path.

    The .ml is 919 lines.  Only a small set of entries reach callers:
    - {!resolve_join_state} and
      {!should_read_legacy_persisted_agent_name} —
      [test/test_mcp_server_eio.ml] exercises both to
      verify the join-required + ephemeral-name fallback
      decisions stay consistent across refactors.
    - {!caller_agent_name_from_arguments} — isolates the
      HTTP [_agent_name] vs legacy [agent_name] precedence
      contract without running the full dispatcher.
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

val caller_agent_name_from_arguments : Yojson.Safe.t -> string option
(** Returns the explicit caller identity carried in [tools/call]
    arguments.  The internal HTTP-auth marker [_agent_name] wins
    over legacy [agent_name]; legacy [agent_name] remains the fallback
    for direct callers and old MCP clients.  Blank and ["unknown"]
    values are ignored. *)

(** {1 Test hooks} *)

module For_testing : sig
  val cleanup_internal_keeper_runtime_resource :
    during_exception:bool -> label:string -> (unit -> unit) -> unit
  (** Runs one internal keeper runtime cleanup action.  Non-cancellation
      cleanup failures are logged and suppressed; cancellation is propagated
      only when cleanup is not running behind a primary exception. *)

  val run_with_cleanup_preserving_primary :
    cleanup:(during_exception:bool -> unit -> unit) -> (unit -> 'a) -> 'a
  (** Runs [f] and then [cleanup].  If [f] raises, cleanup runs on the
      exception path and the original exception/backtrace is re-raised. *)
end

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
  Tool_result.t
(** Routes [(name, arguments)] to the matching tool tag
    via {!Tool_dispatch.lookup_tag} and runs the handler.
    Returns a structured {!Tool_result.t} carrying success
    flag, typed payload, tool name, elapsed duration, and
    failure classification.  The wrapper layer
    {!Mcp_server_eio_call_tool.handle_call_tool_eio}
    composes the final JSON-RPC envelope around it.

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
