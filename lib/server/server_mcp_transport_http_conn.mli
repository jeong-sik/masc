(** Server_mcp_transport_http_conn — SSE connection lifecycle
    management.

    Per-session SSE connection registry with rate-limit guard.
    All access to global registries is internally protected by
    atomic CAS loops.  A connection's response belongs to the domain
    that runs the connection: only {!send_raw} and the {!run_sse_pumps}
    supervisor touch it, both on that domain (RFC-0493 §3.2).

    Open'd by sibling modules (`server_mcp_transport_http`,
    `server_mcp_transport_http_agui`) — all top-level bindings
    here flow through into those namespaces. *)

(** {1 Connection state} *)

type sse_conn_info = {
  session_id : string;
  client_id : int;
  response : Server_sse_response.t;
  stop : bool Atomic.t;
  closed : bool Atomic.t;
  stop_promise : unit Eio.Promise.t;
  resolve_stop : unit Eio.Promise.u;
}
(** Concrete record because callers
    ({!Server_mcp_transport_http}, AG-UI bridge) construct it
    via {!make_sse_conn} for the SSE handler.

    [closed] and [stop] are [Atomic.t] because the close paths run
    on different domains: the Sse overflow hook, the maintenance
    fiber and shutdown close from outside the connection's domain.
    [closed] is the single-close guard:
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

(** {1 Connect-rate guard knobs}

    Values come from {!Env_config_runtime.Sse_connect_guard}; the names below
    are that module's.  Since task-538 they are read per call through the
    module's {!Re_read} thunks (the same reader the disable-semantics tests
    pin), not cached at process start. *)

val sse_reconnect_min_interval_s : unit -> float
(** [MASC_SSE_RECONNECT_MIN_INTERVAL_S], default [1.0].  Minimum gap between two SSE connect
    attempts on the same session.  Setting to [0.0] or negative
    disables the per-session cooldown. *)

val sse_connect_window_s : unit -> float
(** [MASC_SSE_CONNECT_WINDOW_S], default [60.0].
    Sliding-window length for the burst-rate guard.  Setting to
    [0.0] or negative disables the window check. *)

val sse_connect_max_in_window : unit -> int
(** [MASC_SSE_CONNECT_MAX_IN_WINDOW], default [10].
    Max connect attempts per [sse_connect_window_s] before the
    guard returns [Error ("window_limit", _)]. *)

(** {1 Connection registry} *)

val register_sse_conn :
  session_id:string -> info:sse_conn_info -> unit
(** [register_sse_conn ~session_id ~info] adds [info] to the
    SSE registry under [session_id].  Replaces any prior entry
    for the same session — callers responsible for stopping
    the previous connection first via {!stop_sse_session}. *)

val stop_sse_session_before : client_id:int -> string -> unit
(** Close the current connection only when its client id is strictly lower than
    [client_id]. A newer or equal-id successor is never closed. *)

val register_sse_conn_if_newer :
  session_id:string -> info:sse_conn_info -> bool
(** Atomically publish [info] only when the current entry is absent or strictly
    older. Returns [false] for an equal or newer current entry. *)

val close_sse_conn : sse_conn_info -> unit
(** [close_sse_conn info] sets [info.closed = true] / [info.stop = true]
    (via the single-close [compare_and_set] claim), resolves the one-shot
    stop promise exactly once, and unregisters the SSE client.
    Idempotent — safe to call multiple times, from any domain.

    It does not close [info.response].  The {!run_sse_pumps} supervisor
    closes it on the connection's domain once the stop promise resolves. *)

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

val stop_sse_conn_if_current : sse_conn_info -> unit
(** Close this connection without removing a successor that reused its session. *)

val stop_sse_session_evict :
  string -> reason:Session_lifecycle_event.evict_reason -> unit
(** [stop_sse_session_evict session_id ~reason] is
    {!stop_sse_session} plus a typed
    {!Session_lifecycle_event.Evict}/{!Session_lifecycle_event.Close}
    pair published on the bus topic (RFC-0099 PR-3).

    No [event: evicted] frame reaches the client: [Sse.register] runs
    the evicted client's [on_disconnect] first, which already stopped
    its connection (#48870). *)

val stop_sse_session_preserve_guard : string -> unit
(** [stop_sse_session_preserve_guard session_id] removes the
    registry entry but **preserves** the connect-rate guard
    state.  Used by intentional disconnect-then-reconnect flows
    (e.g. AG-UI bridge replay) so the rate guard does not
    re-arm and reject the re-connect. *)

val is_active_sse_session : string -> bool
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

val send_raw : sse_conn_info -> string -> Server_sse_response.outcome
(** [send_raw info data] sends [data] with {!Server_sse_response.send},
    which returns once the frame reached the socket, the response
    closed, or the stall bound passed.  On [Written] it touches the SSE
    timestamp via {!Sse.touch}.  Otherwise it closes the connection via
    {!close_sse_conn} and returns the refusal.  A stopped connection
    returns [Closed] without writing.

    Call it only on the connection's domain.  A waiting send can be
    cancelled; the cancellation propagates. *)

val drain_sse :
  sse_conn_info ->
  clock:_ Eio.Time.clock ->
  prime:string ->
  replay:Sse.delivery list ->
  frame_of:(Sse.delivery -> string) ->
  send:(string -> Server_sse_response.outcome) ->
  Sse.delivery_stream ->
  Server_sse_pump.ending
(** [drain_sse info ~clock ~prime ~replay ~frame_of ~send stream] is the
    drain of an MCP GET, AG-UI or presence connection (RFC-0493 §3.2):
    {!Server_sse_pump.run} over [prime], then the [replay] deliveries,
    then the live deliveries of [stream], each live or replayed one
    written as [frame_of] makes it.  The frames already waiting go out
    in one [send], within {!Server_sse_pump.max_batch_bytes}, so a burst
    waits for the client once per batch.  A live delivery the replay
    carried is skipped.  It writes nothing on a quiet stream (the ping
    pump writes the keepalive) and ends with [Source_stopped] once
    [info] is stopped.

    [send] is {!send_raw} on [info], or a wrapper that refuses when the
    connection's workspace scope ended.  Run it as the [drain] of
    {!run_sse_pumps}, on the connection's domain. *)

val make_sse_conn :
  session_id:string ->
  client_id:int ->
  response:Server_sse_response.t ->
  unit ->
  sse_conn_info
(** [make_sse_conn ~session_id ~client_id ~response ()] builds an
    [sse_conn_info] with [stop] and [closed] both [Atomic.make false], and a fresh
    [stop_promise]/[resolve_stop] pair.  All SSE handlers construct connections
    through this so the stop promise is never omitted. *)

val run_sse_pumps :
  sw:Eio.Switch.t ->
  sse_conn_info ->
  drain:(unit -> unit) ->
  ping:(unit -> unit) ->
  unit
(** [run_sse_pumps ~sw info ~drain ~ping] forks the [drain] and [ping]
    pumps under a switch scoped to the connection rather than directly on the
    server-lifetime [sw].  A supervisor forked on [sw] opens a child switch,
    runs both pumps as daemons, and blocks on [info.stop_promise]; resolving
    that promise ({!close_sse_conn} does) releases the child switch and
    cancels both pumps — including a drain fiber blocked in
    [Eio.Stream.take] or in a waiting send (#21548).  A pump that returns
    before the stop (one that logged an exception it caught, such as a prime
    or replay send that raised) stops the connection the same way, so a
    stream never stays open with one pump.

    When both pumps have ended, the switch's release hook removes [info]
    from the registry with {!stop_sse_conn_if_current} and closes
    [info.response].  It runs on the domain that called [run_sse_pumps],
    so call it from the connection's domain.  The hook also runs when
    [sw] is cancelled.  When [sw] is already off, no supervisor starts and
    [run_sse_pumps] does the same release before it returns.  So every
    response handed to [run_sse_pumps] is closed.

    [drain] sends the stream's first frames (prime, replay) before its live
    events ({!drain_sse}), so a stop also cancels a first frame that waits
    for the socket. *)

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

val check_standalone_observer_connect_guard :
  observer_instance_id:string ->
  credential:Masc_domain.agent_credential ->
  (unit, Sse_reject_reason.t * float) result
(** Bound fresh standalone Observer registrations by the existing configured
    sliding window, shared by the validated credential's agent and the admitted
    workspace instance. Different agents and instances have independent windows.
    Session cleanup does not reset this history. This includes concurrent first
    subscriptions; it is not a reconnect-only limit. The per-session minimum
    interval is not applied, so tabs can open concurrently within the window.
    Use this as the required admission callback of
    {!Sse.register_standalone_observer_with_client}, so the exact credential
    charged is the one published. No raw bearer token is kept in the guard. *)

module For_testing : sig
  val check_standalone_observer_connect_guard :
    now:float -> observer_instance_id:string -> credential:Masc_domain.agent_credential ->
    (unit, Sse_reject_reason.t * float) result
  val reap_stale_guards : now:float -> int
end
(** Deterministic timestamps for the same production guard, registry and
    maintenance reaper. This neither seeds private state nor replaces policy.
    It models captured request times completing out of order; it does not
    establish a real multi-domain CAS interleaving. *)
