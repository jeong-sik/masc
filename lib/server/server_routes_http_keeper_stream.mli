(** Server_routes_http_keeper_stream — keeper chat
    streaming HTTP route + payload parser.

    [Server_routes_http.ml] does
    [include Server_routes_http_keeper_stream] (as part
    of the route facade), and
    [server_routes_http_routes_dashboard] does
    [open Server_routes_http_keeper_stream] to reach
    {!parse_keeper_chat_stream_request} +
    {!handle_keeper_chat_stream} +
    {!keeper_chat_stream_error_json} unqualified.  The
    [module Keeper_stream = ...] aliases in 4 sister
    routing modules are leftover from an earlier
    refactor and currently have no call sites — they
    keep working through the type-passthrough but do not
    add to the surface here.

    External surface (3 entries + 1 record):
    - {b request record} ({!keeper_chat_stream_request})
      returned by the parser, consumed by the handler;
      the dashboard route reaches the [.name] field via
      record-pattern access.
    - {b parser} ({!parse_keeper_chat_stream_request})
      reached unqualified by the dashboard route + via
      dotted call from
      [test/test_gate_keeper_backend].
    - {b error envelope}
      ({!keeper_chat_stream_error_json}) reached
      unqualified by the dashboard route when surfacing
      parse / authorization failures.
    - {b SSE handler} ({!handle_keeper_chat_stream})
      drives the per-request SSE stream.

    Internal helpers stay private at this boundary
    (~10 internal lets — [contains_casefold],
    [get_origin] / [cors_headers] adapter helpers,
    [keeper_chat_stream_*] sub-renderers + per-event
    framing, connector-context and legacy model-argument
    payload guards). *)

(** {1 Request record} *)

type keeper_chat_stream_request = {
  name : string;
  message : string;
  timeout_sec : int option;
  turn_instructions : string option;
  surface_context : Yojson.Safe.t option;
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_workspace_id : string;
  attachments : Keeper_chat_store.attachment list;
}
(** Parsed payload of a keeper chat-stream HTTP request.
    [timeout_sec] is clamped to [\[5, 300\]] when
    present.  [turn_instructions] and [surface_context]
    are optional copilot context fields; when
    [turn_instructions] is absent but [surface_context]
    is present, the surface context is formatted and
    injected as turn instructions.  [channel] and
    [channel_workspace_id] are required together when any
    connector context is supplied; [channel_user_id] and
    [channel_user_name] are optional. *)

(** {1 Parsing} *)

val parse_keeper_chat_stream_request :
  string -> (keeper_chat_stream_request, string) result
(** Parses the HTTP body string into a
    {!keeper_chat_stream_request}.  Returns
    [Error reason] on JSON shape mismatches, missing
    [name] / [message], partial connector context, or
    presence of legacy keeper model args removed by the
    runtime rewrite. *)

(** {1 Error envelope} *)

val keeper_chat_stream_error_json : string -> Yojson.Safe.t
(** [{ "error": { "message": "…" } }] envelope for
    parse / handler errors. *)

(** {1 Queue request handlers} *)

val handle_keeper_chat_request_result :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [GET /api/v1/keepers/chat/requests/<request_id>].
    Reads the async keeper message request state directly from
    {!Keeper_msg_async} without requiring an MCP session. *)

val handle_keeper_chat_request_cancel :
  Mcp_server.server_state -> Httpun.Request.t -> Httpun.Reqd.t -> unit
(** Drives [POST /api/v1/keepers/chat/requests/<request_id>/cancel].
    Cancels a live async keeper message request when it is still
    cancellable. *)

(** {1 SSE handler} *)

val handle_keeper_chat_stream :
  sw:Eio.Switch.t ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  Mcp_server.server_state ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  keeper_chat_stream_request ->
  unit
(** Drives the [POST /api/keeper/chat-stream] SSE
    response.  Streams keeper turn events back to the
    client over [text/event-stream] with CORS + cache
    suppression headers, gated by the per-request switch
    [sw] and the wall clock [clock].  Closes the writer
    on switch release; surfaces handler exceptions
    through the SSE stream rather than the HTTP envelope
    once the headers have flushed. *)

(** {1 Turn execution (shared between HTTP handler and queue consumer)} *)

val process_single_turn :
  state:Mcp_server.server_state ->
  clock:[> float Eio.Time.clock_ty ] Eio.Resource.t ->
  sw:Eio.Switch.t ->
  auth_token:string option ->
  thread_id:string ->
  closed:bool ref ->
  payload:keeper_chat_stream_request ->
  run_id:string ->
  message_id:string ->
  agent_name:string ->
  events:Keeper_chat_events.keeper_chat_event Eio.Stream.t ->
  unit
(** Execute a single keeper turn, publishing events to the provided
    event stream.  [closed] is a mutable flag that suppresses worker
    event pushes when set to [true] (used by the SSE adapter when the
    HTTP stream is closed).  [auth_token] is [None] for queue-consumer
    turns where no HTTP request is available. *)

(** {1 Testing helpers} *)

module For_testing : sig
  val parse_request : string -> (keeper_chat_stream_request, string) result
  val has_connector_context : keeper_chat_stream_request -> bool
  val has_external_speaker : keeper_chat_stream_request -> bool
  val message_for_request : keeper_chat_stream_request -> string
  val chat_surface_of_request : keeper_chat_stream_request -> Surface_ref.t
  val chat_speaker_of_request : keeper_chat_stream_request -> Keeper_chat_store.speaker
  val turn_instructions_for_request : keeper_chat_stream_request -> string option
  val args_of_request : keeper_chat_stream_request -> Yojson.Safe.t
  val format_surface_context : Yojson.Safe.t -> string
  val surface_context_to_instructions : Yojson.Safe.t -> string option
end
