(** Server_ws_standalone — standalone WebSocket server for MASC MCP.

    Runs on a dedicated TCP port (default 8937, configurable via
    [MASC_WS_PORT]).  Enabled by default; disable with
    [MASC_WS_ENABLED=0].

    Unlike the [/ws] upgrade path on the HTTP port, this server
    owns the full TCP socket and drives the ws-direct connection
    driver ({!Ws_direct_eio.Server}, RFC-0287) end-to-end — TCP
    accept, the 101 handshake, and the frame loop.

    Session state is shared with {!Server_mcp_transport_ws}: the
    same [sessions] hashtable, [send_to_session], and
    [cleanup_session] are reused.  This module only handles TCP
    accept + connection-handler wiring. *)

val default_port : int
(** Pinned to {!Env_config.Transport.ws_port}.  The SSOT for the
    MASC WebSocket port — every consumer (agent_card,
    transport_read_model, server_bootstrap_http) reads from this
    value rather than re-resolving the env var. *)

val configured_port : unit -> int
(** [configured_port ()] re-reads the env var on each call.
    Used by callers that need the port at boot time after env
    has been parsed.  In practice resolves to the same value as
    {!default_port} unless the environment changes mid-process. *)

val is_enabled : unit -> bool
(** [is_enabled ()] delegates to {!Transport_metrics.ws_enabled}.
    Default: [true].  Disable with [MASC_WS_ENABLED=0] /
    [MASC_WS_ENABLED=false].  This is the SSOT for "should
    standalone WS be running" — agent_card, transport_read_model,
    and the bootstrap loop all branch on this predicate. *)

module For_testing : sig
  val heartbeat_interval_s : float

  val pong_timeout_intervals : int

  val missed_pong_threshold : unit -> int
  (** Configurable missed-pong threshold (default: {!pong_timeout_intervals}).
      Reads [MASC_WS_MISSED_PONG_THRESHOLD] once; clamps negative values to 0. *)

  val accept_backoff_cap_s : float

  val next_accept_backoff : float -> float
  (** Deterministic base for the next accept-error backoff.  The production
      loop adds jitter on top of this value. *)
end

val start :
  sw:Eio.Switch.t ->
  env:Eio_unix.Stdenv.base ->
  on_message:(string -> string -> unit) ->
  unit
(** [start ~sw ~env ~on_message] forks a fiber that listens on
    [127.0.0.1:<configured_port>] for WebSocket connections.

    {2 Disabled path}

    When {!is_enabled} returns [false], records the
    [ws_listen_status: "disabled"] metric, logs at
    {!Log.Server.info}, and returns immediately without forking.

    {2 Per-connection switch}

    Every accepted connection runs under its own
    [Eio.Switch.run] so the accepted [flow] is released the
    moment the WS handler exits, not when the long-lived server
    [sw] closes.  Without this, each connection's FD lingers in
    the kernel [CLOSED] state until shutdown — a 1Hz dashboard
    reconnect (claude-in-chrome's playwright Chrome polls
    [ws://127.0.0.1:8937/]) accumulates ~3,600 FDs/h and can starve
    every keeper subprocess.  The pattern matches
    [http_server_h2.ml]'s accept loop.

    {2 Bind failure isolation}

    Bind failures (EADDRINUSE or other [Unix.Unix_error]) are
    caught locally and reported via [ws_listen_status:
    "bind_failed"] + {!Log.Server.error}.  This is intentional —
    propagating to the bootstrap catch-all would mark the entire
    startup as Degraded (#3408).

    {2 Accept-error backoff}

    Accept errors trigger an exponential backoff (initial 0.05s,
    factor 1.5, capped at 2.0s) so a tight error loop does not
    saturate the CPU.  Cancellation is propagated through the
    backoff sleep.

    {2 Heartbeat + pong timeout}

    Each connection forks a protocol-level ping fiber on its own
    switch.  The server tracks [last_pong_at] and resets the
    missed-pong counter on every client [Pong].  After
    [pong_timeout_intervals] consecutive unanswered pings, the
    session is closed so dead peers do not accumulate.

    {2 [on_message]}

    Called as [on_message session_id body_str] for each inbound
    text frame (and continuation frames after a fragmented
    message reassembles).  Binary frames also flow through this
    callback — the dispatcher decides how to interpret the
    payload. *)
