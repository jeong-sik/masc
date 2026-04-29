(** Server_mcp_transport_ws — WebSocket transport for the
    MASC MCP server.  Bidirectional JSON-RPC over WS,
    replacing SSE for dashboard / agent connections that
    need full-duplex.

    External surface (16 entries + 3 types):
    - {b session record} ({!ws_session}) — concrete because
      [server_ws_standalone] passes session values to
      {!read_inbound_message_frame} /
      {!send_dashboard_or_raw_sse} and reaches the live
      {!sessions} table directly.
    - {b SSE parse record} ({!parsed_sse_event}) — exposed
      so the regression test at
      [test/test_transport_integration] can pattern-match
      on [parsed.event_type] / [parsed.slice].
    - {b send-outcome variant} ({!send_outcome}) — pattern
      matched at [server_runtime_bootstrap] when
      dispatching agent broadcasts.
    - {b session lifecycle}
      ({!new_session}, {!cleanup_session}, {!close_all},
      {!session_count}, {!sessions}, {!with_sessions_rw},
      {!next_id}).
    - {b inbound framing}
      ({!read_inbound_message_frame}).
    - {b dashboard JSON-RPC handlers}
      ({!dashboard_hello}, {!dashboard_subscribe},
      {!dashboard_unsubscribe}, {!dashboard_ack},
      {!set_dashboard_snapshot_provider}).
    - {b outbound delivery}
      ({!send_to_session_result},
      {!send_dashboard_or_raw_sse},
      {!parse_sse_dashboard_event}).

    Internal helpers stay private at this boundary
    ([sha1], [sessions_mutex], [slice_index] +
    [slice_index_*] family, [__test_*] hooks,
    [log_ws_delivery_dropped], [send_frame_bytes] /
    [websocket_text_payload] / [send_text] /
    [bytes_cache] / [bytes_of_shared_text] /
    [send_text_shared] / [send_text_*_checked] /
    [send_json_checked], [jsonrpc_notification],
    [next_dashboard_seq], [valid_dashboard_slice] /
    [dashboard_slice_for_sse_type],
    [dashboard_session_result], [find_session],
    [dashboard_snapshot_provider] cell,
    [dashboard_auth_success_payload],
    [verify_dashboard_token], [dashboard_snapshot],
    [parse_cache] / [sse_data_prefix] /
    [extract_sse_data_*],
    [dashboard_delta_for_parsed] /
    [dashboard_delta_for_sse], [env_cache_ttl_s],
    [client_buffer_limit_cache] /
    [client_buffer_limit_bytes],
    [session_is_backpressured],
    [slice_index_enabled_cache] /
    [slice_index_enabled],
    [__test_reset_env_caches],
    [read_payload_string], [handle_inbound_text],
    [upgrade_connection], [send_to_session],
    [broadcast_ws]). *)

(** {1 Session record} *)

type ws_session = {
  id : string;
  wsd : Httpun_ws.Wsd.t;
  mutable closed : bool;
  mutable dashboard_authenticated : bool;
  mutable dashboard_agent : string option;
  mutable dashboard_route : string option;
  dashboard_slices : (string, unit) Hashtbl.t;
  mutable dashboard_seq : int;
  mutable dashboard_last_ack_seq : int;
  mutable dashboard_last_buffered_amount : int;
  mutable inbound_partial_text : Buffer.t option;
}
(** Per-WS session state.  Concrete record because
    [server_ws_standalone] threads the value through
    {!read_inbound_message_frame} +
    {!send_dashboard_or_raw_sse} and reaches the
    {!sessions} table directly.  Mutable fields track
    the dashboard handshake / ack state machine; see the
    [#10648] / dashboard-ws.v1 protocol notes in the .ml
    for the field semantics. *)

(** {1 SSE parse record} *)

type parsed_sse_event = {
  event_type : string;
  slice : string option;
  payload : Yojson.Safe.t;
  broadcast_ts : float;
}
(** Result of {!parse_sse_dashboard_event}.  Exposed for
    the [#10194] regression test which pattern-matches on
    [parsed.event_type] / [parsed.slice]. *)

(** {1 Send outcome} *)

type send_outcome =
  | Sent
  | Session_gone
  | Send_failed
(** Three-way outcome of {!send_to_session_result}.
    [Sent] is the happy path; [Session_gone] is the
    expected case after the client disconnects;
    [Send_failed] indicates a wire-level failure that
    warrants operator attention (#10648). *)

(** {1 Session registry} *)

val sessions : (string, ws_session) Hashtbl.t
(** Live session table keyed by session id.  Reads /
    writes must be guarded by {!with_sessions_rw} (or
    held under the same Eio mutex via the slice-index
    helpers).  Reached directly by
    [server_ws_standalone] when wiring upgrade handlers. *)

val with_sessions_rw : (unit -> 'a) -> 'a
(** Runs [f] under the sessions mutex in read/write
    mode.  All mutations to {!sessions} must go through
    this guard. *)

val session_count : unit -> int
(** Current number of live sessions.  Read by the shutdown
    hook, the bootstrap loops, and the read-model
    transport probe. *)

val next_id : unit -> string
(** Generates a fresh session id.  Internal counter is
    monotonically increasing for the process lifetime. *)

val new_session : id:string -> wsd:Httpun_ws.Wsd.t -> ws_session
(** Builds a fresh {!ws_session} with [closed = false]
    and the dashboard handshake state cleared.  Caller
    inserts the result into {!sessions} under
    {!with_sessions_rw}. *)

val cleanup_session : string -> unit
(** Removes the session from {!sessions} (and the
    slice-fanout side index).  Idempotent — calling on
    an unknown id is a silent no-op. *)

val close_all : unit -> int
(** Closes every live WS session.  Returns the number of
    sessions that were drained.  Used by the shutdown
    hook (timing telemetry) and the WS regression test. *)

(** {1 Inbound framing} *)

val read_inbound_message_frame :
  ws_session ->
  on_message:(string -> string -> unit) ->
  is_fin:bool ->
  len:int ->
  Httpun_ws.Payload.t ->
  unit
(** Consumes a single WS data frame off [payload],
    accumulates partial-text fragments across [is_fin =
    false] frames, and invokes [on_message ~session_id
    ~body] when a final fragment arrives. *)

(** {1 Outbound delivery} *)

val send_to_session_result : string -> string -> send_outcome
(** Sends [text] to the session named by id.  Returns
    {!Sent} / {!Session_gone} / {!Send_failed}. *)

val send_dashboard_or_raw_sse : ws_session -> string -> bool
(** Pushes an SSE event payload to a dashboard-subscribed
    WS session — gates on {!session_is_backpressured}
    and per-slice subscription set.  Returns [true] if
    the send was attempted (or skipped due to backpressure
    / slice mismatch — both keep the wire alive); [false]
    on a hard send failure. *)

val parse_sse_dashboard_event :
  string -> parsed_sse_event option
(** Parses an SSE-formatted broadcast string into
    {!parsed_sse_event}, or [None] when the wire format
    does not match the expected ["data:" + JSON]
    convention.  Internal cache collapses repeated parses
    of the same physical buffer across the per-broadcast
    fanout. *)

(** {1 Dashboard JSON-RPC handlers} *)

val set_dashboard_snapshot_provider :
  (string -> Yojson.Safe.t option) -> unit
(** Installs the per-slice snapshot lookup used by
    {!dashboard_subscribe} when seeding initial state.
    Called once at server bootstrap. *)

val dashboard_hello :
  base_path:string ->
  session_id:string ->
  ?token:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Authenticates the dashboard session.  [Ok payload]
    on success carries the protocol version + per-slice
    snapshot; [Error msg] otherwise (unknown session,
    bad token, etc). *)

val dashboard_subscribe :
  session_id:string ->
  ?route:string ->
  slices:string list ->
  unit ->
  (Yojson.Safe.t, string) result
(** Adds [slices] to the session's subscription set
    (after validating each slice is known).  Requires a
    prior {!dashboard_hello}. *)

val dashboard_unsubscribe :
  session_id:string ->
  ?slices:string list ->
  unit ->
  (Yojson.Safe.t, string) result
(** Drops [slices] from the subscription set.  When
    [?slices] is [None], unsubscribes from every slice.
    Requires a prior {!dashboard_hello}. *)

val dashboard_ack :
  session_id:string ->
  seq:int ->
  ?buffered_amount:int ->
  unit ->
  (Yojson.Safe.t, string) result
(** Records the client's ack of [seq] and the optional
    [WebSocket.bufferedAmount] reading.  Used by the
    backpressure observer to gate further sends when the
    client cannot keep up. *)

(** {1 Test-only seams (via [module Ws =] alias)}

    [test/test_ws_transport.ml] takes
    [module Ws = Masc_mcp.Server_mcp_transport_ws] and
    reaches white-box helpers / state probes through that
    alias.  Pinned here so the test compiles against the
    production .mli; production callers stay confined to
    the public lifecycle / handler family above. *)

val valid_dashboard_slice : string -> bool
(** Returns [true] for the canonical slice names
    ([shell] / [execution] / [operator] / [transport] /
    [namespace] / [composite] / [board] / [goals]).
    Mirrored into {!dashboard_subscribe}'s validation. *)

val client_buffer_limit_bytes : unit -> int
(** Resolved client-buffer threshold (in bytes) used by
    {!session_is_backpressured}.  Cached for
    [env_cache_ttl_s] seconds; the test resets the
    cache via {!__test_reset_env_caches}. *)

val slice_index_enabled : unit -> bool
(** Whether the per-slice fanout side index is active.
    Cached identically to {!client_buffer_limit_bytes}. *)

val slice_index_size : unit -> int
(** Total ([slice] × [session]) entries across the side
    index.  Equals the sum of subscribed-slice counts
    over every session. *)

val slice_index_subscribers : string -> string list
(** Session ids subscribed to [slice].  Returns [\[\]]
    when [slice] is unknown or has no subscribers. *)

val bytes_of_shared_text : string -> Bytes.t
(** Returns the WebSocket frame bytes for [text],
    re-using a single-entry physical-equality cache so
    the per-broadcast fanout collapses to one encoding
    pass. *)

val __test_slice_index_add :
  session_id:string -> slice:string -> unit
(** Test-only seam: drives the slice index without going
    through {!dashboard_subscribe}. *)

val __test_slice_index_remove :
  session_id:string -> slice:string -> unit
(** Test-only seam: inverse of {!__test_slice_index_add}. *)

val __test_slice_index_remove_session : string -> unit
(** Test-only seam: drops every slice subscription for a
    session id. *)

val __test_reset_env_caches : unit -> unit
(** Test-only seam: resets the
    {!client_buffer_limit_bytes} and
    {!slice_index_enabled} caches so the next call
    re-reads the environment. *)
