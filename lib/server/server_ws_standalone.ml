(** Standalone WebSocket server for MASC MCP.

    Runs on a separate port (default 8937, configurable via MASC_WS_PORT).
    Enabled by default. Disable with MASC_WS_ENABLED=0.

    Unlike the /ws upgrade path on the HTTP port, this server owns the
    full TCP socket, so httpun-ws can run the HTTP->WS upgrade lifecycle
    end-to-end without conflicting with gluten's protocol management.

    Session state is shared with {!Server_mcp_transport_ws}: the same
    [sessions] hashtable, [send_to_session], and [cleanup_session] are
    reused.  This module only handles TCP accept + connection handler
    wiring. *)

module Ws = Httpun_ws
module Ws_eio = Httpun_ws_eio

(** SSOT: [Env_config.Transport.ws_port]. *)
let default_port = Env_config.Transport.ws_port

(** Read the configured WS port from environment or use default. *)
let configured_port () = Env_config.Transport.ws_port

(** Check whether standalone WS is enabled (default: enabled).
    Disable with MASC_WS_ENABLED=0 or MASC_WS_ENABLED=false. *)
let is_enabled () =
  Transport_metrics.ws_enabled ()

(** WebSocket handler factory.

    For each accepted connection, httpun-ws-eio calls this with the
    client address and a [Wsd.t].  We create a session in the shared
    registry and wire frame callbacks to [on_message]. *)
let make_websocket_handler ~on_message _client_addr (wsd : Ws.Wsd.t) :
    Ws.Websocket_connection.input_handlers =
  let session_id = Server_mcp_transport_ws.next_id () in
  let session = Server_mcp_transport_ws.new_session ~id:session_id ~wsd in
  Server_mcp_transport_ws.with_sessions_rw (fun () ->
    Hashtbl.replace Server_mcp_transport_ws.sessions session_id session);
  Transport_metrics.set_ws_sessions
    (Server_mcp_transport_ws.with_sessions_rw (fun () ->
       Hashtbl.length Server_mcp_transport_ws.sessions));
  (* Register as SSE external subscriber for broadcast events *)
  Sse.subscribe_external ~id:session_id
    ~is_alive:(fun () ->
      not session.closed && not (Ws.Wsd.is_closed session.wsd))
    ~callback:(fun sse_event ->
      if not session.closed
         && not
              (Server_mcp_transport_ws.send_dashboard_or_raw_sse session
                 sse_event)
      then
        Server_mcp_transport_ws.cleanup_session session_id)
    ();
  (* #10875: see lib/server/server_mcp_transport_ws.ml — connect log
     emitted at DEBUG, close path classifies on lifetime. *)
  Log.Server.debug "WebSocket session %s connected (standalone port)" session_id;
  { Ws.Websocket_connection.
    frame = (fun ~opcode ~is_fin ~len payload ->
      match opcode with
      | `Text | `Binary | `Continuation ->
        Server_mcp_transport_ws.read_inbound_message_frame session
          ~on_message ~is_fin ~len payload
      | `Ping ->
        Ws.Wsd.send_pong wsd;
        Ws.Payload.close payload
      | `Connection_close ->
        Server_mcp_transport_ws.cleanup_session session_id;
        Ws.Payload.close payload
      | `Pong | `Other _ ->
        Ws.Payload.close payload
    );
    eof = (fun ?error:_ () ->
      Server_mcp_transport_ws.cleanup_session session_id)
  }

(** Start the standalone WebSocket server.

    Forks a fiber that listens for TCP connections and runs the
    httpun-ws-eio connection handler for each.  Does nothing if
    [MASC_WS_ENABLED] is not set.

    @param sw Eio switch for structured concurrency.
    @param env Eio environment (for network access).
    @param on_message Called with [(session_id, body_str)] for each
      inbound text frame. *)
let start
    ~(sw : Eio.Switch.t)
    ~(env : Eio_unix.Stdenv.base)
    ~(on_message : string -> string -> unit)
  : unit =
  if not (is_enabled ()) then begin
    Transport_metrics.set_ws_runtime_listening false;
    Transport_metrics.set_ws_listen_status "disabled";
    Log.Server.info "WebSocket transport disabled (MASC_WS_ENABLED=0)"
  end else begin
    let port = configured_port () in
    let net = Eio.Stdenv.net env in
    let addr = `Tcp (Eio.Net.Ipaddr.V4.loopback, port) in
    (* Isolate bind failure so it does not propagate to the bootstrap
       catch-all and mark the entire startup as Degraded (#3408). *)
    match Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:128 addr with
    | socket ->
      Transport_metrics.set_ws_runtime_listening true;
      Transport_metrics.set_ws_listen_status "listening";
      let connection_handler =
        Ws_eio.Server.create_connection_handler ~sw
          (make_websocket_handler ~on_message)
      in
      Eio.Fiber.fork ~sw (fun () ->
        (* Safe: finally is Atomic.set — no I/O, no exception risk *)
        Fun.protect
          ~finally:(fun () ->
            Transport_metrics.set_ws_runtime_listening false;
            Transport_metrics.set_ws_listen_status "stopped")
          (fun () ->
            Log.Server.info "WebSocket server starting on port %d" port;
            let rec accept_loop backoff_s =
              try
                let flow, client_addr = Eio.Net.accept ~sw socket in
                Eio.Fiber.fork ~sw (fun () ->
                  (* Per-connection switch so the accepted [flow] is
                     released the moment the WS handler exits, not when
                     the long-lived server [sw] closes. Without this
                     each connection's FD lingers in the kernel [CLOSED]
                     state until shutdown — a 1Hz dashboard reconnect
                     (claude-in-chrome's playwright Chrome polls
                     [ws://127.0.0.1:8937/]) accumulates ~3 600 FDs/h,
                     tripping [admission_queue_rejected: fd count >= 90%]
                     and starving every keeper subprocess. Pattern
                     matches [http_server_h2.ml]'s accept loop. *)
                  Eio.Switch.run (fun conn_sw ->
                    Eio.Switch.on_release conn_sw (fun () ->
                      try Eio.Flow.close flow with
                      | Eio.Cancel.Cancelled _ as e -> raise e
                      | exn ->
                        Log.Server.warn
                          "[ws-standalone] flow close failed: %s"
                          (Printexc.to_string exn));
                    try connection_handler client_addr flow
                    with
                    | Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                      Log.Server.warn "WS standalone handler error: %s"
                        (Printexc.to_string exn)));
                accept_loop 0.05
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Server.error "WS standalone accept error: %s"
                  (Printexc.to_string exn);
                (* Backoff to avoid tight error loops *)
                (try Eio.Time.sleep (Eio.Stdenv.clock env) backoff_s
                 with Eio.Cancel.Cancelled _ as e -> raise e
                    | exn ->
                        Log.Server.warn
                          "WS standalone backoff sleep failed on port %d (backoff=%.2fs): %s"
                          port backoff_s (Printexc.to_string exn));
                let next_backoff = Float.min 2.0 (backoff_s *. 1.5) in
                accept_loop next_backoff
            in
            accept_loop 0.05))
    | exception (Eio.Cancel.Cancelled _ as e) -> raise e
    | exception Unix.Unix_error (Unix.EADDRINUSE, _, _) ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error
        "WebSocket transport unavailable on 127.0.0.1:%d: port already in use"
        port
    | exception exn ->
      Transport_metrics.set_ws_runtime_listening false;
      Transport_metrics.set_ws_listen_status "bind_failed";
      Log.Server.error "WebSocket bind failed on port %d: %s"
        port (Printexc.to_string exn)
  end
