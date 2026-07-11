(** Mcp_server_eio_execute — inner [tools/call] dispatcher.

    Only a small set of entries reach callers:
    - {!caller_agent_name_from_arguments} — isolates the
      HTTP [_agent_name] caller identity contract without running
      the full dispatcher.
    - {!execute_tool_eio} — invoked by
      [lib/server/server_runtime_bootstrap.ml] and threaded
      through {!Mcp_server_eio_call_tool.handle_call_tool_eio}
      as its [~execute_tool_eio] callback.
    - {!wait_for_message_eio} — re-exposed because
      [lib/mcp_server_eio.ml] does
      [include Mcp_server_eio_execute] and reaches it
      unqualified.

    Internal helpers stay private at this boundary
    ([log_mcp_exn] re-export,
    [silent_auth_token_error_kind],
    [direct_call_block_message]).  Caller-name origin classification
    now lives in {!Mcp_server_eio_caller_identity.minted_name_is_transient}
    (a total match over the carried origin), replacing the deleted
    [Client_name_kind] string classifier.  The [execute_tool_eio]
    body itself contains many internal sub-helpers
    (audit wrappers, tool dispatchers, error formatters)
    that are local to its lexical scope. *)

val caller_agent_name_from_arguments : Yojson.Safe.t -> string option
(** Returns the explicit caller identity carried in [tools/call]
    arguments.  Only the internal HTTP-auth marker [_agent_name] is
    accepted; tool-domain [agent_name] arguments are not caller
    identity.  Blank and ["unknown"] values are ignored. *)

val resolve_bind_state :
  workspace_initialized:bool ->
  bind_required:bool ->
  agent_name:string ->
  check_join:(string -> bool) ->
  bool
(** Test hook for the bind-required guard's read decision. *)

(** {1 Test hooks} *)

module For_testing : sig
  type dispatch_failure =
    | Missing_tag
    | No_handler

  val resolve_tag_dispatch :
    lookup_tag:(string -> Tool_dispatch.module_tag option) ->
    dispatch_tag:(Tool_dispatch.module_tag -> Tool_result.result option) ->
    name:string ->
    (Tool_result.result, dispatch_failure) result
  (** Resolves one registered route without collapsing a missing tag and a
      registered route that returns no handler result. *)

  val dispatch_failure_result :
    tool_name:string -> dispatch_failure -> Tool_result.result
  (** Lowers a typed dispatch failure to an explicit [Runtime_failure]. *)

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
  Tool_result.result
(** Routes [(name, arguments)] to the matching tool tag
    via {!Tool_dispatch.lookup_tag} and runs the handler.
    Returns a structured {!Tool_result.result} carrying success
    flag, typed payload, tool name, elapsed duration, and
    failure classification.  The wrapper layer
    {!Mcp_server_eio_call_tool.handle_call_tool_eio}
    composes the final JSON-RPC envelope around it.

    Side effects on the request scope:
    - Refreshes [Eio_context.set_switch] / [set_clock] so
      downstream helpers that still consult ambient
      handles see the current request scope (tests can
      otherwise leave a finished switch in the global slot).
    - Bumps the [Otel_metric_store.record_request] counter for
      every inbound call.

    [profile] defaults to [Full]; [internal_keeper_runtime]
    defaults to [false] (set [true] for keeper-runtime
    callers that bypass the public-tool whitelist).

    Type variables [{'sw, 'clk, 'auth}] stay polymorphic
    (cycle 205 lesson) so the dispatcher's body — which
    only passes them through to internal helpers — does
    not over-constrain the caller chain. *)

(** {1 Runtime re-exports} *)

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
