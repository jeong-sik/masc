(** Server_mcp_transport_http_agui — AG-UI SSE bridge handler.

    Single public entry point: {!handle_ag_ui_events} services
    [GET /ag-ui/events] by binding a per-session SSE stream to the
    MASC event bus, converting each MASC event to the AG-UI SSE wire
    format, and managing two background fibers (drain + ping).

    The internal surface is deliberately narrow.  All helpers
    (`ag_ui_event_of_masc_event`, `sse_stream_headers` re-export, the
    local `sse_ping_interval_s` shadow) stay private so the surface
    stays auditable. *)

val handle_ag_ui_events :
  deps:Server_mcp_transport_http_types.deps ->
  Httpun.Request.t ->
  Httpun.Reqd.t ->
  unit
(** [handle_ag_ui_events ~deps request reqd] handles
    [GET /ag-ui/events].

    {1 Lifecycle}

    1. Resolve session id from cookie / headers (generates a fresh id
       when none present — {!Mcp_session.get_or_generate}).
    2. Resolve protocol version from the per-session table.
    3. Read [last-event-id] header (replay anchor).
    4. Run {!check_sse_connect_guard} — on rate-limit reject with
       {!respond_sse_rate_limited} (HTTP 429) and stop.
    5. {!stop_sse_session_preserve_guard} on the session id (drops a
       previous SSE stream for the same session without re-arming the
       guard).
    6. Register with {!Sse.register} — receives a per-client event
       stream and a possibly-evicted prior session id.  Evicted
       session is fully stopped.
    7. Send a synthetic AG-UI [Run_started] prime event so the client
       can observe the connection has settled.
    8. If [last-event-id] was present, replay missed events via
       {!Sse.get_events_after}.
    9. Spawn two fibers under the runtime switch:
       - drain: pulls from per-session stream, writes raw to client,
         self-terminates on send failure.
       - ping: sleeps 30s, writes ": ping\\n\\n" comment frame to
         keep middleboxes from idling out the connection.

    {1 Cancellation contract}

    Both fibers re-raise [Eio.Cancel.Cancelled] from every level so
    a switch teardown propagates immediately.  Any other exception
    is logged at {!Log.Server.error} or {!Log.Server.warn}; the fiber
    that raised stops the session via
    {!stop_sse_session_preserve_guard}.  A transient send failure on
    one fiber does not necessarily kill the other — the second fiber
    notices [info.stop = true] on its next iteration.

    {1 Boot-time fast path}

    When [deps.get_runtime_result ()] returns [Error] (runtime not
    yet bootstrapped), the handler skips fiber spawn and logs at
    {!Log.Server.debug}.  The HTTP response is already in flight at
    this point — clients see a stream that emits the prime event
    and any replay events but no live updates.  The client SDK is
    expected to retry on stream end.

    {1 Ping interval}

    Pinned at 30 seconds (matches
    {!Server_mcp_transport_http_headers.sse_ping_interval_s}).  The
    duplicate constant is intentional: the headers module value is
    the operator-visible constant for HTTP keep-alive negotiation,
    while this handler uses a local shadow to keep the AG-UI fiber
    independent of header-module evolution.  A future "let's unify"
    refactor must touch the duplicate explicitly. *)
