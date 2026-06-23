(** Standalone WebSocket server for MASC MCP.

    Runs on a separate port (default 8937, configurable via MASC_WS_PORT).
    Session state is shared with {!Server_mcp_transport_ws}; this module only
    wires TCP accept + the ws-direct connection driver (RFC-0287). *)

module Ws_server = Ws_direct_eio.Server

(** SSOT: [Env_config.Transport.ws_port]. *)
let default_port = Env_config.Transport.ws_port

(** Read the configured WS port from environment or use default. *)
let configured_port () = Env_config.Transport.ws_port

(** Check whether standalone WS is enabled (default: enabled).
    Disable with MASC_WS_ENABLED=0 or MASC_WS_ENABLED=false. *)
let is_enabled () = Transport_metrics.ws_enabled ()

(** Interval between protocol-level heartbeat pings on each WS session. *)
let heartbeat_interval_s = 30.0

(** Default consecutive unanswered pings before the server closes the session.
    Override with [MASC_WS_MISSED_PONG_THRESHOLD]. *)
let pong_timeout_intervals = 3

(** Configurable missed-pong threshold. [0] disables the guard; negatives are
    clamped to [0].  Read once per session. *)
let missed_pong_threshold () =
  max 0 (Env_config_core.get_int ~default:pong_timeout_intervals "MASC_WS_MISSED_PONG_THRESHOLD")

(** Cap for accept-error exponential backoff. *)
let accept_backoff_cap_s = 5.0

(** Factor for accept-error backoff jitter (±20%). *)
let accept_backoff_jitter_frac = 0.2

(* RFC-0287: the ws-direct Endpoint parses and validates the Close frame
   (RFC 6455 §5.5.1) and hands [on_close] the code + reason directly, so there
   is no longer a raw close payload to read off the wire here. The former CPS
   close-payload reader and its pure helpers (truncate / summarize /
   immediate_summary / plan_chunk) were production-dead after that swap and are
   removed. *)

module For_testing = struct
  let heartbeat_interval_s = heartbeat_interval_s
  let pong_timeout_intervals = pong_timeout_intervals
  let missed_pong_threshold = missed_pong_threshold
  let accept_backoff_cap_s = accept_backoff_cap_s

  (** Deterministic next accept-error backoff (production adds jitter). *)
  let next_accept_backoff backoff_s = Float.min accept_backoff_cap_s (backoff_s *. 1.5)
end

(* RFC-0287: the ws-direct Endpoint parses and validates the Close frame, so
   [on_close] hands over the code + reason directly — no need to read the close
   payload off the wire (the former CPS [log_ws_client_close_payload]). The pure
   summary helpers (immediate / summarize / plan_ws_close_payload chunk) stay
   exported for their unit tests. *)
let log_ws_client_close ~session_id ~(code : int option) ~reason =
  let code_str = match code with Some c -> string_of_int c | None -> "none" in
  Log.Server.debug "[ws-standalone] session %s client close (code=%s reason=%S)"
    session_id code_str reason
;;

(** WebSocket handler factory for the standalone listener.  Delegates to the
    shared MCP session protocol
    ({!Server_mcp_transport_ws.mcp_websocket_handler}, RFC-0287 §4) and injects
    the standalone close diagnostic as an observability hook.  [~sw] is the
    per-connection switch so the heartbeat fiber exits with the connection. *)
let make_websocket_handler ~sw ~clock ~on_message _client_addr
    (wsd : Ws_direct_core.Endpoint.Wsd.t)
  : Ws_direct_core.Endpoint.handlers
  =
  Server_mcp_transport_ws.mcp_websocket_handler
    ~sw
    ~clock
    ~on_close_log:log_ws_client_close
    ~on_eof:(fun ~session_id ->
      Log.Server.debug "[ws-standalone] session %s eof" session_id)
    ~on_message
    ~origin_label:"standalone port"
    wsd
;;

(** Start the standalone WebSocket server.  Does nothing if
    [MASC_WS_ENABLED] is not set. *)
let start
      ~(sw : Eio.Switch.t)
      ~(env : Eio_unix.Stdenv.base)
      ~(on_message : string -> string -> unit)
  : unit
  =
  if not (is_enabled ())
  then (
    Transport_metrics.set_ws_runtime_listening false;
    Transport_metrics.set_ws_listen_status "disabled";
    Log.Server.info "WebSocket transport disabled (MASC_WS_ENABLED=0)")
  else (
    let port = configured_port () in
    let net = Eio.Stdenv.net env in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    (* Isolate bind failure so it does not propagate to the bootstrap
       catch-all and mark the entire startup as Degraded (#3408). *)
    match Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 addr with
    | socket ->
      Transport_metrics.set_ws_runtime_listening true;
      Transport_metrics.set_ws_listen_status "listening";
      let clock = Eio.Stdenv.clock env in
      Eio.Fiber.fork ~sw (fun () ->
        (* Safe: finally is Atomic.set — no I/O, no exception risk *)
        Eio_guard.protect
          ~finally:(fun () ->
            Transport_metrics.set_ws_runtime_listening false;
            Transport_metrics.set_ws_listen_status "stopped")
          (fun () ->
             Log.Server.info "WebSocket server starting on port %d" port;
             let rec accept_loop backoff_s =
               try
                 let flow, client_addr = Eio.Net.accept ~sw socket in
                 Eio.Fiber.fork ~sw (fun () ->
                   (* Per-connection switch releases [flow] as soon as the
                      handler exits, preventing FD accumulation.  The connection
                      handler and WebSocket handler are created here so the
                      heartbeat fiber runs on [conn_sw], not the server switch. *)
                   Eio.Switch.run (fun conn_sw ->
                     Eio.Switch.on_release conn_sw (fun () ->
                       try Eio.Flow.close flow with
                       | Eio.Cancel.Cancelled _ as e -> raise e
                       | exn ->
                         Log.Server.warn
                           "[ws-standalone] flow close failed: %s"
                           (Printexc.to_string exn));
                     (* ws-direct reads the upgrade request off the raw socket,
                        replies 101, then drives the Server-role Endpoint.
                        max_frame stays at the default here (less-exposed
                        MASC_WS_PORT); max_message is enforced. *)
                     try
                       Ws_server.handle
                         ~max_message:
                           (Server_mcp_transport_ws.max_inbound_message_bytes ())
                         flow
                         (make_websocket_handler ~sw:conn_sw ~clock ~on_message
                            client_addr)
                     with
                     | Eio.Cancel.Cancelled _ as e -> raise e
                     | exn ->
                       (match
                          Http_server_eio.Late_response.classify_write_failure exn
                        with
                        | Some _ ->
                          Log.Server.debug
                            "WS standalone handler closed before write completed"
                        | None ->
                          Log.Server.warn
                            "WS standalone handler error: %s"
                            (Printexc.to_string exn))));
                 accept_loop 0.05
               with
               | Eio.Cancel.Cancelled _ as e -> raise e
               | exn ->
                 Log.Server.error
                   "WS standalone accept error: %s"
                   (Printexc.to_string exn);
                 (* Back off exponentially with jitter and a 5s cap. *)
                 (try Eio.Time.sleep (Eio.Stdenv.clock env) backoff_s with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Server.warn
                      "WS standalone backoff sleep failed on port %d (backoff=%.2fs): %s"
                      port
                      backoff_s
                      (Printexc.to_string exn));
                 let base = Float.min accept_backoff_cap_s (backoff_s *. 1.5) in
                 let jitter =
                   base *. accept_backoff_jitter_frac *. ((Random.float 2.0) -. 1.0) (* NDT-OK: intentional jitter to avoid thundering-herd reconnects. *)
                 in
                 let next_backoff = Float.max 0.05 (base +. jitter) in
                 accept_loop next_backoff
             in
             accept_loop 0.05))
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error
        "WebSocket transport unavailable on %s:%d: port already in use"
        Masc_network_defaults.masc_http_default_host
        port
    | exception exn ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error
        "WebSocket bind failed on port %d: %s"
        port
        (Printexc.to_string exn))
;;
