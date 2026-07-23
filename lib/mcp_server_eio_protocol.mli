(** Mcp_server_eio_protocol — top-level JSON-RPC dispatcher
    + stdio transport for the Eio MCP server.

    Owns:
    - the {b resource subscription registry}
      ([resource_subscriptions] hashtbl + per-session
      lock) and the [resources/subscribe] /
      [resources/unsubscribe] handlers,
    - the {b tools-list-changed} broadcast plumbing
      ({!broadcast_tools_list_changed},
      {!maybe_emit_resource_notifications}),
    - the {b transport mode detector}
      ({!detect_mode}, {!transport_mode}) used by the
      stdio entry point,
    - the {b top-level dispatcher} ({!handle_request}) that
      routes every incoming JSON-RPC method to its
      handler,
    - the {b stdio runner} ({!run_stdio}) that loops
      over framed / line-delimited messages from
      [Eio.Stdenv.stdin].

    The .ml is 825 lines but only 7 entries reach
    callers.  Internal helpers stay private at this
    boundary
    ([TP] alias, the [make_response] / [make_error] /
    [is_jsonrpc_v2] / [is_jsonrpc_response] / [get_id] /
    [is_valid_request_id] / [jsonrpc_request_of_yojson]
    re-exports of {!Mcp_transport_protocol},
    [unavailable_tool_message],
    [resource_subscription_mutex],
    [with_resource_subscription_lock],
    [resource_subscriptions] table, [resource_is_dynamic],
    [subscribe_resource_for_session],
    [unsubscribe_resource_for_session],
    [jsonrpc_notification],
    [send_resource_updated_notification],
    [dedup_strings], [core_status_resource_ids] +
    [task_resource_ids] + [agent_resource_ids] +
    [message_resource_ids],
    [resource_id_of_uri],
    [affected_resource_ids_for_tool],
    [handle_initialize_eio],
    [handle_list_resource_templates_eio],
    [handle_list_prompts_eio], [handle_get_prompt_eio],
    [handle_resources_subscribe_eio],
    [handle_resources_unsubscribe_eio],
    [optional_string_member], [string_list_member],
    [dashboard_response_or_error],
    [handle_dashboard_hello_eio] /
    [handle_dashboard_subscribe_eio] /
    [handle_dashboard_unsubscribe_eio] /
    [handle_dashboard_ack_eio] /
    [handle_dashboard_ack_notification],
    [tool_call_outcome],
    [jsonrpc_id_label], [tool_profile_label],
    [mcp_tool_call_log_details],
    [read_line_message], [write_framed_message],
    [write_line_message]). *)

(** {1 Tool profile} *)

type tool_profile = Mcp_server_eio_types.tool_profile =
  | Full
  | Managed_agent
  | Operator_remote
(** Capability profile selected per request.  Pinned at
    this boundary because {!handle_request} accepts
    [?profile] and downstream callers
    ([Mcp_server_eio.handle_request] in
    [lib/mcp_server_eio.ml]) coerce it through the
    {!Mcp_server_eio_types.tool_profile} alias. *)

(** {1 Authentication requirement} *)

module Auth_requirement : sig
  type t =
    | Public
    | Requires_auth
    | Internal_only
end
(** Per-handler authentication classification.  The
    {!handle_request} dispatcher is the single enforcement
    point; every method routes through it before invoking
    its handler. *)

(** {1 Session-bound resource subscription cleanup} *)

val clear_resource_subscriptions_for_session : string -> unit
(** Drops every entry the session subscribed to.
    Called on session teardown so the
    [resources/updated] broadcaster does not push to a
    dead session id. *)

(** {1 Notifications} *)

val broadcast_tools_list_changed : unit -> unit
(** Emits [notifications/tools/list_changed] to every
    session.  Fired after a tool registry change (e.g.
    long-running mutation start / stop) so dashboards can
    refresh their tool inspector without polling. *)

val maybe_emit_resource_notifications :
  success:bool -> tool_name:string -> unit
(** Inspects the tool name + outcome and, when the call
    is known to mutate persisted state (board /
    activity / workspace / task / agent), emits
    [resources/updated] notifications for the affected
    resource ids.  No-op on [success = false] so a
    failed call does not invalidate caches. *)

(** {1 Top-level dispatcher} *)

val handle_request :
  handle_call_tool_eio:
    (sw:'sw ->
     clock:([> float Eio.Time.clock_ty ] as 'clk) Eio.Resource.t ->
     profile:tool_profile ->
     ?mcp_session_id:string ->
     ?auth_token:string ->
     internal_keeper_runtime:bool ->
     Mcp_server.server_state ->
     Yojson.Safe.t ->
     Yojson.Safe.t ->
     Yojson.Safe.t) ->
  handle_read_resource_eio:
    (Mcp_server.server_state ->
     Yojson.Safe.t ->
     Yojson.Safe.t option ->
     Yojson.Safe.t) ->
  clock:'clk Eio.Resource.t ->
  sw:'sw ->
  ?profile:tool_profile ->
  ?mcp_session_id:string ->
  ?otel_mcp_protocol_version:string ->
  ?otel_transport_context:Otel_dispatch_hook.transport_context ->
  ?auth_token:string ->
  ?internal_keeper_runtime:bool ->
  Mcp_server.server_state ->
  string ->
  Yojson.Safe.t
(** [handle_request ~handle_call_tool_eio
    ~handle_read_resource_eio ~clock ~sw ?profile
    ?mcp_session_id ?otel_mcp_protocol_version ?otel_transport_context
    ?auth_token ?internal_keeper_runtime
    state request_str] parses [request_str] as JSON-RPC,
    routes the [method] to the matching internal handler
    (server/discover / initialize / tools/list / tools/call
    / resources/list / resources/read / resources/subscribe /
    unsubscribe / list_resource_templates / prompts/list /
    prompts/get / dashboard/* family), and returns the response
    envelope.

    Parse failures return a [-32700] Parse error envelope
    with the original error string in [data].
    [profile] defaults to [Full]; [internal_keeper_runtime]
    defaults to [false] (the keeper runtime overrides the
    tool whitelist when set).

    [handle_call_tool_eio] and [handle_read_resource_eio]
    are passed in to break the cyclic dep between this
    module, {!Mcp_server_eio_call_tool}, and
    {!Mcp_server_eio_resource}. *)

(** {1 Stdio transport} *)

type transport_mode =
  | Framed
      (** Content-Length prefixed — MCP stdio mode. *)
  | LineDelimited
      (** One JSON per line — simple mode. *)

val detect_mode : string -> transport_mode
(** Inspects the first line off the stdin buffer; if it
    starts (case-insensitive) with [content-length],
    selects {!Framed}, otherwise {!LineDelimited}.  The
    decision is made once per connection and pinned for
    the rest of the run. *)

val run_stdio :
  handle_request:
    (clock:([> float Eio.Time.clock_ty ] as 'clk) Eio.Resource.t ->
     sw:'sw ->
     mcp_session_id:string ->
     Mcp_server.server_state ->
     string ->
     Yojson.Safe.t) ->
  sw:'sw ->
  env:< clock : 'clk Eio.Resource.t
      ; stdin : [> Eio.Flow.source_ty ] Eio.Resource.t
      ; stdout : [> Eio.Flow.sink_ty ] Eio.Resource.t
      ; .. > ->
  Mcp_server.server_state ->
  unit
(** Stdio entry point.  Reads from [Eio.Stdenv.stdin env]
    (max 16 MiB buffer), detects {!transport_mode} from the
    first line, then loops feeding messages through the
    injected [handle_request] and writing the response
    back to [Eio.Stdenv.stdout env] in the same framing.
    Cancellation propagates through [sw]; EOF / [Eio.Cancel]
    exits cleanly. *)

val register_dashboard_ws_handlers :
  hello:(base_path:string -> session_id:string -> ?token:string -> unit -> (Yojson.Safe.t, string) result) ->
  subscribe:(session_id:string -> ?route:string -> slices:string list -> unit -> (Yojson.Safe.t, string) result) ->
  unsubscribe:(session_id:string -> ?slices:string list -> unit -> (Yojson.Safe.t, string) result) ->
  ping:(session_id:string -> unit -> (Yojson.Safe.t, string) result) ->
  unit

val register_dashboard_ack :
  (session_id:string ->
   seq:int ->
   ?buffered_amount:int ->
   unit ->
   (Yojson.Safe.t, string) result) ->
  unit
