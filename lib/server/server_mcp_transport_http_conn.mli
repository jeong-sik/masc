(** Server_mcp_transport_http_conn — SSE connection lifecycle
    management.

    Per-session SSE connection registry with rate-limit guard.
    All access to global registries is internally protected by
    atomic CAS loops; per-connection writes are protected by
    each {!sse_conn_info}'s mutex.

    Open'd by sibling modules (`server_mcp_transport_http`,
    `server_mcp_transport_http_agui`) — all top-level bindings
    here flow through into those namespaces. *)

(** {1 Connection state} *)

type sse_conn_info = {
  session_id : string;
  client_id : int;
  writer : Httpun.Body.Writer.t;
  mutex : Eio.Mutex.t;
  stop : bool Atomic.t;
  closed : bool Atomic.t;
  stop_promise : unit Eio.Promise.t;
  resolve_stop : unit Eio.Promise.u;
}
(** Concrete record because callers
    ({!Server_mcp_transport_http}, AG-UI bridge) construct it
    via {!make_sse_conn} for the SSE handler.  [client_id = -1]
    indicates an inline response (see {!make_inline_sse_conn}).

    [closed] and [stop] are [Atomic.t] because the close paths run
    on different domains once serving moves off the main domain
    (a client disconnect on the serving domain vs keeper-driven
    eviction / shutdown on the main domain) — they are not confined
    to one fiber under [mutex].  [closed] is the single-close guard:
    {!close_sse_conn} flips it false->true with [compare_and_set] so
    exactly one caller runs the close body.

    Readers treat either [stop=true] or [closed=true] as terminal, so
    the intermediate state where one flag is set before the other is
    benign.  The safety invariant is not that a particular transient
    is unobservable, but that every reader branches to the closed/stop
    path as soon as it sees either flag.

    [stop_promise]/[resolve_stop] is resolved exactly once by
    {!close_sse_conn} (guaranteed by the [closed] claim above; a
    second resolve of a one-shot promise raises [Invalid_argument]);
    {!run_sse_pumps} awaits it to release the per-connection pump
    switch.  Construct via {!make_sse_conn} so the promise is always
    paired with the connection. *)

(** {1 Connect-rate guard env knobs} *)

val sse_reconnect_min_interval_s : float
(** Cached at module-init from [MASC_SSE_RECONNECT_MIN_INTERVAL_S]
    (default [1.0]).  Minimum gap between two SSE connect
    attempts on the same session.  Setting to [0.0] or negative
    disables the per-session cooldown. *)

val sse_connect_window_s : float
(** Cached from [MASC_SSE_CONNECT_WINDOW_S] (default [60.0]).
    Sliding-window length for the burst-rate guard.  Setting to
    [0.0] or negative disables the window check. *)

val sse_connect_max_in_window : int
(** Cached from [MASC_SSE_CONNECT_MAX_IN_WINDOW] (default [10]).
    Max connect attempts per [sse_connect_window_s] before the
    guard returns [Error ("window_limit", _)]. *)

(** {1 Connection registry} *)

val register_sse_conn_if_absent :
  session_id:string -> info:sse_conn_info -> bool
(** Publishes [info] only if [session_id] has no connection.  Returns [false]
    instead of overwriting a newer generation that won a DELETE/reconnect race. *)

val close_sse_conn : sse_conn_info -> unit
(** [close_sse_conn info] sets [info.closed = true] / [info.stop = true]
    (via the single-close [compare_and_set] claim), resolves the one-shot
    stop promise exactly once, closes the writer, and unregisters the SSE
    client.  Idempotent — safe to call multiple times.

    The writer is closed under [info.mutex] so it never runs concurrently
    with a [send_raw] / evict write on another domain; consequently this
    must be called from within an Eio scheduler context (every production
    close path is).  Errors during writer close log at {!Log.Misc.debug}
    but do not propagate. *)

val __test_claim_close : sse_conn_info -> bool
(** Test-only seam: the close-claim used by {!close_sse_conn}.  Returns [true]
    for the single caller that wins the right to run the close body (resolve the
    one-shot stop promise).  Exposed so the cross-domain regression test can
    race two domains on one connection and assert at most one wins — two winners
    would double-resolve the promise and crash. *)

val stop_sse_session : string -> unit
(** [stop_sse_session session_id] removes the registry entry
    AND clears the connect-rate guard state for [session_id].
    Calls {!close_sse_conn} on the removed connection. *)

val stop_sse_session_evict :
  string -> reason:Session_lifecycle_event.evict_reason -> unit
(** [stop_sse_session_evict session_id ~reason] is
    {!stop_sse_session} *plus* (a) a best-effort SSE
    [event: evicted] close frame written to the client before the
    writer closes, and (b) a typed
    {!Session_lifecycle_event.Evict}/{!Session_lifecycle_event.Close}
    pair published on the bus topic.

    Frame format: [event: evicted\\ndata: {"type":"evicted","reason":<reason>}\\n\\n]
    where [reason] is {!Session_lifecycle_event.evict_reason_to_string}.
    Operators and SDK clients key off the literal [event: evicted]
    line — RFC-0099 §3.

    Frame write is best-effort: a failure (writer already closed,
    network gone) logs at debug and continues to the close + publish
    path. Eviction does not abort on observability failure.

    PR-3 (RFC-0099) introduces this variant; cap-exceeded /
    backpressure / idle-timeout sites that previously called
    {!stop_sse_session} silently should migrate to this when the
    eviction is a *server-policy decision* (not a client
    disconnect). *)

val stop_sse_session_preserve_guard : string -> unit
(** [stop_sse_session_preserve_guard session_id] removes the
    registry entry but **preserves** the connect-rate guard
    state.  Used by intentional disconnect-then-reconnect flows
    (e.g. AG-UI bridge replay) so the rate guard does not
    re-arm and reject the re-connect. *)

val stop_sse_session_if_current_preserve_guard : string -> int -> unit
(** Stops only the connection whose immutable SSE client id matches.  Stale
    pumps and reconnect fibers cannot detach a newer connection that reused the
    same wire session id. *)

val is_active_sse_session : string -> bool
val current_sse_connection_client_id : string -> int option
(** Returns the immutable client generation in the HTTP connection registry. *)
val active_session_count : unit -> int

val reap_stale_guards : unit -> int
(** [reap_stale_guards ()] removes connect-guard entries whose
    deadline has passed AND whose session has no active
    connection.  Returns the number of reaped entries.  Called
    periodically by the cleanup loop to keep the guard map
    bounded. *)

val close_all_sse_connections : unit -> unit
(** [close_all_sse_connections ()] closes every SSE connection
    and clears both registries.  Logs the count at
    {!Log.Server.info} with prefix
    [["MASC MCP: Closed N SSE connections"]] — operator
    runbooks key off this prefix. *)

(** {1 SSE I/O} *)

val send_raw : sse_conn_info -> string -> bool
(** [send_raw info data] writes [data] to the SSE writer under
    the per-connection mutex, flushes, and touches the SSE
    timestamp via {!Sse.touch}.  Returns [false] when the
    connection is closed/stopped, the writer is closed, OR an
    exception occurred during write (in which case the
    connection is closed via {!close_sse_conn}).

    [Eio.Cancel.Cancelled] re-raises verbatim — fiber
    cancellation does not silently mark the connection as
    failed.  Returns [true] on successful flush. *)

val make_sse_conn :
  session_id:string ->
  client_id:int ->
  writer:Httpun.Body.Writer.t ->
  mutex:Eio.Mutex.t ->
  unit ->
  sse_conn_info
(** [make_sse_conn ~session_id ~client_id ~writer ~mutex ()] builds an
    [sse_conn_info] with [stop] and [closed] both [Atomic.make false], and a fresh
    [stop_promise]/[resolve_stop] pair.  All SSE handlers construct connections
    through this so the stop promise is never omitted. *)

val run_sse_pumps :
  sw:Eio.Switch.t ->
  stop_promise:unit Eio.Promise.t ->
  drain:(unit -> unit) ->
  ping:(unit -> unit) ->
  unit
(** [run_sse_pumps ~sw ~stop_promise ~drain ~ping] forks the [drain] and [ping]
    pumps under a switch scoped to the connection rather than directly on the
    server-lifetime [sw].  A supervisor forked on [sw] opens a child switch,
    runs both pumps as daemons, and blocks on [stop_promise]; resolving that
    promise (callers pass [info.stop_promise], which {!close_sse_conn} resolves)
    releases the child switch and cancels both pumps — including a drain fiber
    blocked in [Eio.Stream.take] that the [info.stop] flag alone cannot
    interrupt (#21548). *)

val make_inline_sse_conn :
  session_id:string -> Httpun.Body.Writer.t -> sse_conn_info
(** [make_inline_sse_conn ~session_id writer] constructs an
    [sse_conn_info] for an inline (non-registered) response.
    Sets [client_id = -1] marker so {!send_raw}'s
    [Sse.unregister_if_current] is a no-op for these
    connections.

    Used for one-shot SSE responses that bypass the per-session
    registry (e.g. SSE error envelopes that do not warrant a
    persistent slot). *)

(** {1 Connect-rate guard} *)

val check_sse_connect_guard :
  string -> (unit, Sse_reject_reason.t * float) result
(** [check_sse_connect_guard session_id] verifies that the
    session's SSE connect rate is within the configured limits
    AND records the new connect time on success.

    Returns:
    - [Ok ()] when the connect is allowed.
    - [Error (Sse_reject_reason.Session_cooldown, wait_s)] when
      {!sse_reconnect_min_interval_s} has not elapsed since the
      last connect on this session.
    - [Error (Sse_reject_reason.Window_limit, wait_s)] when the
      session has hit {!sse_connect_max_in_window} connects within
      {!sse_connect_window_s}.  [wait_s] is the time until the
      oldest connect-time entry leaves the window.

    The literal error tags ([["session_cooldown"]],
    [["window_limit"]]) are operator-visible — runbooks key
    off these to differentiate cooldown vs burst-limit
    rejections. *)
