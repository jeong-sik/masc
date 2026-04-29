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
    framing, [legacy_models_present] /
    [has_connector_context] payload guards). *)

(** {1 Request record} *)

type keeper_chat_stream_request = {
  name : string;
  message : string;
  timeout_sec : int option;
  channel : string;
  channel_user_id : string;
  channel_user_name : string;
  channel_room_id : string;
}
(** Parsed payload of a keeper chat-stream HTTP request.
    [timeout_sec] is clamped to [\[5, 300\]] when
    present.  [channel] / [channel_user_id] /
    [channel_user_name] / [channel_room_id] are all
    required together when any connector context is
    supplied; otherwise they are accepted as empty. *)

(** {1 Parsing} *)

val parse_keeper_chat_stream_request :
  string -> (keeper_chat_stream_request, string) result
(** Parses the HTTP body string into a
    {!keeper_chat_stream_request}.  Returns
    [Error reason] on JSON shape mismatches, missing
    [name] / [message], partial connector context, or
    presence of legacy keeper model args removed by the
    cascade rewrite. *)

(** {1 Error envelope} *)

val keeper_chat_stream_error_json : string -> Yojson.Safe.t
(** [{ "error": { "message": "…" } }] envelope for
    parse / handler errors. *)

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
