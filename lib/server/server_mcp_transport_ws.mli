(** Server_mcp_transport_ws — WebSocket transport for the
    MASC MCP server.  Bidirectional JSON-RPC over WS,
    replacing SSE for dashboard / agent connections that
    need full-duplex.

    External surface:
    - {b session record} ({!ws_session}) — concrete because
      [server_ws_standalone] passes session values to
      {!read_inbound_message_frame} /
      {!send_dashboard_or_raw_sse} and reaches the live
      {!sessions} table directly.
    - {b inbound size decisions}
      ({!inbound_size_rejection}, {!inbound_size_decision}).
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
      ({!read_inbound_message_frame},
      {!max_inbound_dispatches_per_session},
      {!try_begin_inbound_dispatch},
      {!finish_inbound_dispatch}).
    - {b dashboard JSON-RPC handlers}
      ({!dashboard_hello}, {!dashboard_subscribe},
      {!dashboard_unsubscribe}, {!dashboard_ping},
      {!dashboard_ack},
      {!set_dashboard_snapshot_provider}).
    - {b outbound delivery}
      ({!send_to_session_result},
      {!send_dashboard_or_raw_sse},
      {!parse_sse_dashboard_event}).

    Internal helpers stay private at this boundary
    ([sha1], [sessions_mutex], [slice_index] +
    [slice_index_*] family, [__test_*] hooks,
    [inbound_message_handler],
    [log_ws_delivery_dropped], [send_text_bigstring] /
    [websocket_text_payload] / [send_text] /
    [bigstring_cache] / [bigstring_of_shared_text] /
    [send_text_shared] / [send_text_*_checked] /
    [send_json_checked], [jsonrpc_notification],
    [next_dashboard_seq], [valid_dashboard_slice] /
    [dashboard_slice_for_sse_type],
    [dashboard_session_result], [find_session],
    [detach_session_for_close] / [close_detached_session_wsd] /
    [update_ws_session_count_metric],
    [dashboard_snapshot_provider] cell,
    [dashboard_auth_success_payload],
    [verify_dashboard_token], [dashboard_snapshot],
    [parse_cache] / [sse_data_prefix] /
    [extract_sse_data_*],
    [dashboard_delta_payload_text_cache] /
    [dashboard_delta_payload_text_for_parsed] /
    [dashboard_delta_seq_notification] /
    [send_dashboard_delta_frame] /
    [send_dashboard_delta_for_parsed] /
    [send_dashboard_delta_for_sse], [env_cache_ttl_s],
    [client_buffer_limit_cache] /
    [client_buffer_limit_bytes],
    [dashboard_ack_stale_threshold_cache] /
    [dashboard_ack_stale_threshold_s],
    [session_is_backpressured],
    [max_inbound_frame_bytes] /
    [max_inbound_message_bytes],
    [classify_inbound_frame_size] /
    [classify_inbound_message_size],
    [slice_index_enabled_cache] /
    [slice_index_enabled],
    [__test_reset_env_caches],
    [read_payload_string], [inbound_accumulate], [read_data_frame],
    [send_to_session],
    [broadcast_ws]). *)

(** {1 Session record} *)

type dashboard_auth_state =
  | Unauthenticated
  | Authenticated of { agent : string option }
(** Dashboard handshake state for a session.  Set once by [dashboard_hello],
    read on the SSE forward hot path and the dashboard RPC auth gates.  Held
    in an [Atomic.t] field so the single write and many reads are tear-free if
    dashboard serving moves off the main Eio domain (RFC-0204 §8.4, Phase 1). *)

(* RFC-0287: inbound reassembly + UTF-8 validation moved into the ws-direct
   Connection layer, which delivers complete messages to the Endpoint
   [on_message] handler. The [Ws_inbound] reassembler and the manual
   read/classify machinery are gone; only the [max_inbound_*] size knobs remain,
   fed to [Endpoint.create]. *)

type ws_session = {
  id : string;
  wsd : Ws_direct_core.Endpoint.Wsd.t;
  closed : bool Atomic.t;
  write_mutex : Eio.Mutex.t;
  last_pong_at : float Atomic.t;
  dashboard_auth : dashboard_auth_state Atomic.t;
  dashboard_route : string option Atomic.t;
  dashboard_slices : string list Atomic.t;
  dashboard_seq : int Atomic.t;
  dashboard_last_ack_seq : int Atomic.t;
  dashboard_last_buffered_amount : int Atomic.t;
  dashboard_last_ack_at : float Atomic.t;
  dashboard_last_delta_seq : int Atomic.t;
  dashboard_last_delta_at : float Atomic.t;
  inbound_dispatches : int Atomic.t;
}
(** Per-WS session state.  Concrete record because
    [server_ws_standalone] threads the value through
    {!read_inbound_message_frame} +
    {!send_dashboard_or_raw_sse} and reaches the
    {!sessions} table directly.  The dashboard handshake /
    ack state machine is tracked in the [dashboard_*] fields;
    see the [#10648] / dashboard-ws.v1 protocol notes in the
    .ml for the field semantics.

    All cross-domain state is held in [Atomic.t]: the
    connection scalars ([closed], [last_pong_at],
    [inbound_dispatches]); the per-session dashboard delivery
    counters ([dashboard_seq], the ack / delta / buffered fields)
    and the subscribed-[dashboard_slices] snapshot, all
    read / written on the SSE fanout callback that fires from both
    the main domain (keeper / refresh broadcasts) and serving
    handlers; and [dashboard_route], written under concurrent
    per-session dispatch.  Plain mutable fields would race once
    serving moves to its own domain (RFC-0204 Phase 3).  All writes
    to [wsd] are serialized through [write_mutex]. *)

val dashboard_auth_is_authenticated : dashboard_auth_state -> bool
(** [true] once [dashboard_hello] has authenticated the session. *)

val dashboard_auth_agent : dashboard_auth_state -> string option
(** Resolved agent name for an [Authenticated] state, [None] otherwise. *)

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

type dashboard_delta_payload_frame = {
  slice : string;
  text : string;
}
(** Shared dashboard/delta payload frame for one SSE broadcast.  [text] is a
    serialized JSON-RPC notification without the per-session [seq], so every
    subscribed session can share the same physical string/bytes in fan-out. *)

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

val new_session : id:string -> wsd:Ws_direct_core.Endpoint.Wsd.t -> ws_session
(** Builds a fresh {!ws_session} with [closed = false]
    and the dashboard handshake state cleared.  Caller
    inserts the result into {!sessions} under
    {!with_sessions_rw}. *)

val is_session_closed : ws_session -> bool
(** [true] once the session has been closed locally or the httpun-ws writer
    has shut down.  Safe to call from any fiber. *)

val record_pong : ws_session -> unit
(** Refresh [last_pong_at] on a received pong; the single liveness signal read
    by {!heartbeat_should_close} (#21509). *)

val heartbeat_should_close :
  now:float -> last_pong_at:float -> threshold:int -> interval_s:float -> bool
(** [true] when a session should be closed for pong-timeout: it has gone
    [threshold] whole [interval_s]-second intervals with no pong (i.e.
    [now -. last_pong_at > threshold * interval_s]).  A client that keeps
    answering refreshes [last_pong_at] and is never closed.  [threshold <= 0]
    disables the guard.  Shared by the /ws upgrade heartbeat and the standalone
    heartbeat so liveness is single-source (#21509). *)
(** Refresh [last_pong_at] and reset the missed-pong counter.  Called by the
    WS frame handler on every [Pong] frame. *)

val cleanup_session : string -> unit
(** Removes the session from {!sessions} (and the
    slice-fanout side index).  Idempotent — calling on
    an unknown id is a silent no-op. *)

val close_all : unit -> int
(** Closes every live WS session.  Returns the number of
    sessions that were drained.  Used by the shutdown
    hook (timing telemetry) and the WS regression test. *)

(** {1 Inbound framing} *)

type inbound_dispatch_rejection = {
  reason : string;
  limit : int;
  in_flight : int;
}
(** Structured reject reason for per-session inbound dispatch admission. *)

type inbound_dispatch_admission =
  | Inbound_dispatch_admitted of ws_session
  | Inbound_dispatch_rejected of inbound_dispatch_rejection
  | Inbound_dispatch_session_gone
(** Result of attempting to reserve one per-session inbound dispatch slot. *)

val max_inbound_dispatches_per_session : unit -> int
(** Maximum concurrent JSON-RPC dispatch fibers admitted from one WS session.
    [0] disables the admission cap. *)

val try_begin_inbound_dispatch : string -> inbound_dispatch_admission
(** Reserve one inbound dispatch slot for [session_id].  Returns
    {!Inbound_dispatch_session_gone} if the session is already detached. *)

val finish_inbound_dispatch : ws_session -> unit
(** Release a dispatch slot reserved by {!try_begin_inbound_dispatch}. *)

val set_inbound_message_handler : (string -> string -> unit) -> unit
(** Installs the MCP JSON-RPC dispatcher invoked for inbound WebSocket
    text messages.  Bootstrap sets this once it has a live server state. *)

val dispatch_inbound_message : string -> string -> unit
(** Dispatches an inbound WebSocket message through the currently installed
    handler.  Used by both standalone WS and same-origin [/ws] upgrade paths. *)

val mcp_websocket_handler :
  ?sw:Eio.Switch.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?on_close_log:(session_id:string -> code:int option -> reason:string -> unit) ->
  ?on_eof:(session_id:string -> unit) ->
  on_message:(string -> string -> unit) ->
  origin_label:string ->
  Ws_direct_core.Endpoint.Wsd.t ->
  Ws_direct_core.Endpoint.handlers
(** Single source of truth for the MCP-over-WebSocket session protocol:
    session registration, SSE subscription, liveness heartbeat, and message
    handling.  Shared by the same-origin upgrade path and the standalone
    listener — they differ only in socket attachment, not the session protocol.
    ws-direct delivers complete (reassembled, UTF-8-validated, size-capped)
    messages to [on_message] and auto-replies to pings, so this builds an
    Endpoint handler rather than a frame-opcode switch.  [on_close_log] /
    [on_eof] are observability hooks invoked before cleanup.  RFC-0287 §4.1. *)

val sec_websocket_accept : string -> string
(** [sec_websocket_accept key] computes the RFC 6455 §1.3 handshake response
    token: [base64(sha1(key ^ GUID))].  Exposed for the canonical-vector
    regression test (the GUID and base64/sha1 wiring must not drift). *)

val ws_upgrade_accept : Httpun.Request.t -> (string, string) result
(** Validate an HTTP/1.1 -> WebSocket upgrade request (RFC 6455 §4.2.1): [GET],
    [Upgrade: websocket], [Connection] listing [upgrade], [Sec-WebSocket-Version:
    13], and a [Sec-WebSocket-Key] that base64-decodes to exactly 16 bytes.
    Returns the accept token on success.  Authority validation belongs to the
    shared request-entry gate, so this function intentionally does not re-read
    [Host].  Exposed for unit tests. *)

val respond_and_drive_upgrade :
  upgrade:(Gluten.impl -> unit) ->
  reqd:Httpun.Reqd.t ->
  max_message:int ->
  max_frame:int ->
  handler:(Ws_direct_core.Endpoint.Wsd.t -> Ws_direct_core.Endpoint.handlers) ->
  (unit, string) result
(** Single source of truth for HTTP/1.1 -> WebSocket attachment: validates the
    request (RFC 6455 §4.2.1), writes the 101 on [reqd], then drives the
    post-101 connection by handing a ws-direct Endpoint (Server role, bounded by
    [max_message] / [max_frame]) to the Gluten runtime via [upgrade] as a
    drop-in for the former Httpun_ws.Server_connection.  RFC-0287 §4.1. *)

val upgrade_connection :
  ?sw:Eio.Switch.t ->
  ?clock:float Eio.Time.clock_ty Eio.Resource.t ->
  ?on_message:(string -> string -> unit) ->
  upgrade:(Gluten.impl -> unit) ->
  Httpun.Reqd.t ->
  (unit, string) result
(** Handles an HTTP/1.1 [GET /ws] upgrade on the main HTTP origin using the
    shared MCP session protocol ({!mcp_websocket_handler}) and attachment
    ({!respond_and_drive_upgrade}).  [upgrade] is the Gluten capability
    threaded from the route via {!Http_server_eio.Router.ws_get}.  When [sw]
    and [clock] are provided, forks the protocol-level heartbeat on a
    per-connection switch (a child of [sw]) and closes the session after a
    configurable number of missed pongs. *)

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

val dashboard_ping :
  session_id:string ->
  unit ->
  (Yojson.Safe.t, string) result
(** Lightweight heartbeat endpoint for browser dashboards.
    Requires a prior {!dashboard_hello}; stale or unauthenticated sessions
    fail so the client can reconnect and re-handshake. *)

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
    [module Ws = Masc.Server_mcp_transport_ws] and
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

val dashboard_ack_stale_threshold_s : unit -> float
(** Resolved max age for the latest [dashboard/ack] before outbound dashboard
    sends are considered stale.  [0.0] disables stale-ACK backpressure.
    Cached for [env_cache_ttl_s] seconds; the test resets the cache via
    {!__test_reset_env_caches}. *)

val dashboard_ack_is_stale :
  now:float ->
  last_delta_at:float ->
  last_delta_seq:int ->
  last_ack_seq:int ->
  threshold_s:float ->
  bool
(** Pure stale-ACK predicate used by the dashboard backpressure gate.  Only
    unacknowledged dashboard/delta seqs can become stale; subscribe snapshots
    are excluded because the browser does not ACK them. *)

val max_inbound_frame_bytes : unit -> int
(** Maximum single inbound WebSocket frame payload size.  [0] disables the
    frame gate. *)

val max_inbound_message_bytes : unit -> int
(** Maximum accumulated inbound WebSocket message size across fragments.
    [0] disables the message gate. *)

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

val bigstring_of_shared_text : string -> Bigstringaf.t
(** Returns the WebSocket text payload for [text],
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
    {!dashboard_ack_stale_threshold_s} and
    {!slice_index_enabled} caches so the next call
    re-reads the environment. *)

val __test_missed_pong_threshold : unit -> int
(** Test-only seam: exposes the configured missed-pong threshold so tests can
    verify default / env-var / clamping behavior. *)

val __test_next_dashboard_seq : ws_session -> int
(** Test-only seam: the per-session dashboard seq allocator.  Exposed so the
    cross-domain delivery-state gate can drive two Eio domains through it
    (RFC-0204 Phase 3 prerequisite). *)

val __test_dashboard_seq_value : ws_session -> int
(** Test-only seam: reads the current per-session dashboard seq counter so the
    cross-domain gate can assert the final value equals the total number of
    allocations (no lost updates under true parallelism). *)

val __test_dashboard_delta_payload_text_for_sse :
  string -> dashboard_delta_payload_frame option
(** Test-only seam: serializes the shared dashboard/delta payload frame for
    one SSE broadcast.  The returned text deliberately excludes the
    per-session seq so tests can prove payload serialization is cached by
    physical broadcast reference rather than multiplied by session count. *)
