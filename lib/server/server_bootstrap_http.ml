(** HTTP serving layer for MASC MCP server bootstrap.
    Handles socket creation, accept loops, and protocol detection
    (HTTP/1.1 via httpun-eio, HTTP/2 h2c via h2-eio, or auto-detect). *)

module Http = Http_server_eio

type bind_address_error = Invalid_host of string

(* Ipaddr's message tries both families and spans two lines, so the refusal
   names the host alone. *)
let parse_bind_address host =
  match Ipaddr.of_string host with
  | Ok address -> Ok address
  | Error (`Msg (_ : string)) -> Error (Invalid_host host)
;;

let bind_address_error_to_string = function
  | Invalid_host host ->
    Printf.sprintf
      "Cannot bind host %S: it is not an IPv4 or IPv6 address. --host, or \
       MASC_HOST when the flag is absent, takes an IP address such as %s; a \
       name such as localhost is not resolved."
      host
      Masc_network_defaults.masc_http_default_host
;;

let make_http_config ~address ~port : Http.config =
  let config = { Http.default_config with port; host = Ipaddr.to_string address } in
  let advertised_host =
    if Server_auth.is_unspecified_host config.host
    then Masc_network_defaults.masc_http_default_host
    else config.host
  in
  Unix.putenv Env_config_core.host_env_key config.host;
  Unix.putenv Env_config_core.http_port_env_key (string_of_int config.port);
  Unix.putenv
    Env_config_core.mcp_url_env_key
    (Printf.sprintf "http://%s:%d/mcp" advertised_host config.port);
  (match Sys.getenv_opt Env_config_core.http_base_url_env_key with
   | Some existing when String.trim existing <> "" -> ()
   | _ ->
     Unix.putenv
       Env_config_core.http_base_url_env_key
       (Printf.sprintf "http://%s:%d" advertised_host config.port));
  config
;;

let tcp_address ~address (config : Http.config) =
  `Tcp (Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets address), config.port)
;;

let listen_socket ~sw ~net ~address (config : Http.config) =
  Eio.Net.listen
    net
    ~sw
    ~reuse_addr:true
    ~backlog:config.listen_backlog
    (tcp_address ~address config)
;;

(* Eio 1.3 lets the Unix error of socket, bind and listen through as it is for
   a TCP address, in its posix and its linux backend (a port in use is
   EADDRINUSE), and its interface names no exception. A caller that answers a
   listener that did not bind with a reason binds here, so the case of a port
   in use (test_server_accounts) fails when a later Eio raises another one. *)
let listen_tcp_result ~sw ~net ~backlog address =
  match Eio.Net.listen net ~sw ~reuse_addr:true ~backlog address with
  | socket -> Ok socket
  | exception Unix.Unix_error (error, call, (_ : string)) ->
    Error (Printf.sprintf "%s: %s" call (Unix.error_message error))
;;

let listen_socket_result ~sw ~net ~address (config : Http.config) =
  listen_tcp_result ~sw ~net ~backlog:config.listen_backlog (tcp_address ~address config)
;;

(* The HTTPS listener of one boot (RFC-0512 D6); see the interface. *)
type https_listener =
  { https_port : int
  ; tls : Tls.Config.server
  ; certificate_source : Https_listener_metrics.certificate_source
  }

let print_startup_banner
      ~(config : Http.config)
      ~https
      ~resolved_base
      ~base_path
      ~masc_dir
      ~path_diagnostics
  =
  Printf.printf "MASC MCP Server listening on http://%s:%d\n%!" config.host config.port;
  Printf.printf "   Base path: %s\n%!" resolved_base;
  if resolved_base <> base_path
  then Printf.printf "   Base path (input): %s\n%!" base_path;
  Printf.printf "   MASC dir: %s\n%!" masc_dir;
  List.iter
    (fun line -> Printf.printf "%s\n%!" line)
    (Server_base_path_diagnostics.startup_lines path_diagnostics);
  Printf.printf "   GET  /mcp → SSE stream (notifications)\n%!";
  Printf.printf
    "   POST /mcp → JSON-RPC (Accept: application/json, text/event-stream)\n%!";
  Printf.printf "   DELETE /mcp → Session termination\n%!";
  Printf.printf "   POST /graphql → GraphQL (read-only)\n%!";
  Printf.printf "   GET  /api/v1/activity/events → Activity replay API\n%!";
  Printf.printf "   GET  /health → Health check\n%!";
  (match https with
   | None -> ()
   | Some { https_port; certificate_source; tls = _ } ->
     Printf.printf
       "   HTTPS :%d → TLS 1.3, ALPN h2 + http/1.1 (%s certificate)\n%!"
       https_port
       (Https_listener_metrics.certificate_source_to_string certificate_source));
  if Env_config.Transport.grpc_enabled ()
  then
    Printf.printf
      "   gRPC :%d → Workspace + grpc.health.v1.Health + reflection\n%!"
      Env_config.Transport.grpc_port;
  if Transport_metrics.ws_enabled ()
  then
    Printf.printf "   GET  /ws → same-origin WebSocket upgrade or discovery\n%!"
;;

(** Run a list of cleanups on [sw] release, executing all of them
    even if an earlier one raises a non-Cancel exception.  Each cleanup
    runs under its own [try/with] so a single failure cannot prevent
    the remaining cleanups (RFC-0194 §3 PR-B spirit: an
    [Eio.Switch.on_release] callback must be *all-or-nothing* across
    its cleanup steps).  [Eio.Cancel.Cancelled] propagates as usual so
    structured-concurrency cancellation honors the enclosing fiber.

    List ordering is preserved: cleanups run in the order supplied. *)
let with_cleanups_on_release ~sw cleanups =
  Eio.Switch.on_release sw (fun () ->
    List.iter
      (fun cleanup ->
         try cleanup ()
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "on_release cleanup failed: %s"
             (Printexc.to_string exn))
      cleanups)
;;

let on_connection_release conn_sw ~record_closed ~listener_tag flow =
  with_cleanups_on_release ~sw:conn_sw
    [
      record_closed;
      (fun () ->
         try Eio.Flow.close flow with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "[%s] flow close: %s" listener_tag
             (Printexc.to_string exn));
    ]
;;

let register_listener_lifecycle ~sw ~mode =
  Transport_metrics.record_http_listener_started ~mode;
  let stopped = Atomic.make false in
  let mark_stopped () =
    if Atomic.compare_and_set stopped false true
    then Transport_metrics.record_http_listener_stopped ~mode
  in
  Eio.Switch.on_release sw mark_stopped;
  mark_stopped
;;

let disable_nagle flow =
  (* TCP_NODELAY on accepted connections: small SSE frames (keeper token
     deltas, dashboard broadcasts) are not held for Nagle coalescing (~up to
     40ms/frame under Nagle + delayed ACK). Set per-connection after accept,
     not on the listen socket, because TCP_NODELAY inheritance from a
     listening socket is Linux-only and is NOT inherited on macOS. Graceful
     degradation: if [setsockopt] fails on an unusual socket the connection
     still works (just with Nagle enabled). *)
  try
    Eio_unix.Fd.use_exn "TCP_NODELAY" (Eio_unix.Net.fd flow) (fun ufd ->
      Unix.setsockopt ufd Unix.TCP_NODELAY true)
  with
  | Eio.Cancel.Cancelled _ as e -> raise e
  | _ -> ()

(* RFC-0204 §3.2: a GET or HEAD is a read. The mark covers the handler call
   and the fibers it forks; httpun callbacks that run after the handler has
   returned (body reads, streaming) belong to an answered read and see
   [Background], as do POSTs, gRPC and /mcp tool calls. *)
let with_request_lane (meth : Httpun.Method.t) f =
  match meth with
  | `GET | `HEAD -> Pool_lane.with_read f
  | `POST | `PUT | `DELETE | `CONNECT | `OPTIONS | `TRACE | `Other _ -> f ()

let h1_request_handler request_handler client_addr (reqd : Httpun.Reqd.t Gluten.Reqd.t) =
  with_request_lane (Httpun.Reqd.request reqd.Gluten.Reqd.reqd).meth (fun () ->
    request_handler client_addr reqd)

let h1_error_handler _client_addr ?request:_ error respond =
  let msg =
    match error with
    | `Exn exn -> Printexc.to_string exn
    | `Bad_request -> "Bad request"
    | `Bad_gateway -> "Bad gateway"
    | `Internal_server_error -> "Internal server error"
  in
  let body = respond (Httpun.Headers.of_list [ "content-type", "text/plain" ]) in
  Httpun.Body.Writer.write_string body msg;
  Httpun.Body.Writer.close body
;;

let serve_h1_connection ~sw ~request_handler client_addr flow =
  let conn_handler =
    Httpun_eio.Server.create_connection_handler
      ~sw
      ~request_handler:(h1_request_handler request_handler)
      ~error_handler:h1_error_handler
  in
  Http_reqd.with_connection_switch sw (fun () -> conn_handler client_addr flow)
;;

let shared_h2_resources () =
  Http_h2_response_ledger.create
    ~max_pending_bytes:(H2_response_limits.max_pending_bytes ())
;;

let record_cleartext_accept ~mode latency_s =
  Transport_metrics.record_http_accept ~mode;
  Transport_metrics.record_http_accept_latency ~mode latency_s
;;

(* One accept loop. [record_accept latency_s] runs after every accepted
   connection and [record_accept_error error] after a failed accept, which
   is followed by a backoff sleep; [on_stop ()] runs once when the loop ends
   by cancellation. [serve_connection ~conn_sw client_addr connection] runs
   in a fiber of its own whose release records the close and closes the
   accepted flow. A failure of that connection's switch, from any of its
   fibers, is logged and ends with the connection. [connection] is that flow with the connection's bounds
   (RFC-0518 D4, D6): no listener reads or writes the flow itself. *)
let run_accept_loop
      ~sw
      ~clock
      ~socket
      ~listener_tag
      ~record_accept
      ~record_accept_error
      ~record_closed
      ~on_stop
      serve_connection
  =
  let stopped = Atomic.make false in
  let stop () = if Atomic.compare_and_set stopped false true then on_stop () in
  let rec accept_loop backoff_s =
    try
      let accept_start = Unix.gettimeofday () in
      let flow, client_addr = Eio.Net.accept ~sw socket in
      disable_nagle flow;
      record_accept (Unix.gettimeofday () -. accept_start);
      Eio.Fiber.fork ~sw (fun () ->
        try
          Eio.Switch.run ~name:listener_tag (fun conn_sw ->
            on_connection_release conn_sw ~record_closed ~listener_tag flow;
            let connection =
              Server_connection_socket.wrap ~sw:conn_sw ~clock ~listener_tag client_addr flow
            in
            try serve_connection ~conn_sw client_addr connection with
            | Eio.Cancel.Cancelled _ as e -> raise e
            | exn ->
              Log.Misc.error "[%s] connection error: %s"
                listener_tag (Printexc.to_string exn))
        with
        | exn ->
          (* The connection's switch failed: a fiber or daemon on [conn_sw]
             other than [serve_connection] raised, and [Eio.Switch.run] raises
             it again here. An exception that leaves this fiber fails [sw],
             the listener's switch. [Eio.Fiber.check] raises when this fiber's
             own context, the listener's, is cancelled, so the listener's end
             goes on as it does. Otherwise the failure is this connection's,
             whatever the exception is: a [Cancelled] that a connection fiber
             carried out of some other scope does not cancel the listener. *)
          Eio.Fiber.check ();
          Log.Misc.error "[%s] connection failed: %s"
            listener_tag (Printexc.to_string exn));
      accept_loop 0.05
    with
    | Eio.Cancel.Cancelled _ as e ->
      stop ();
      raise e
    | exn ->
      let error = Printexc.to_string exn in
      record_accept_error error;
      Log.Misc.error "[%s] accept error: %s" listener_tag error;
      (try Eio.Time.sleep clock backoff_s with
       | Eio.Cancel.Cancelled _ as e -> raise e
       | exn ->
         Log.Misc.warn "[%s] backoff sleep: %s"
           listener_tag (Printexc.to_string exn));
      accept_loop (Float.min 2.0 (backoff_s *. 1.5))
  in
  accept_loop 0.05
;;

let not_prepared ~listener_tag client_addr what =
  Log.Http.debug
    "[%s] %s %s within %.0fs: connection closed"
    listener_tag
    (Format.asprintf "%a" Eio.Net.Sockaddr.pp client_addr)
    what
    Server_connection_socket.preparation_bound_s
;;

let sent_nothing = "sent nothing"

let serve ~sw ~clock ~socket ~addr_label ~request_handler =
  let mode = "h1" in
  (* Stable listener identity: the [h1 host:port] tag lets error log lines
     name *which* listener emitted them when a process runs multiple HTTP
     servers. *)
  let listener_tag = Printf.sprintf "%s %s" mode addr_label in
  let mark_stopped = register_listener_lifecycle ~sw ~mode in
  run_accept_loop
    ~sw
    ~clock
    ~socket
    ~listener_tag
    ~record_accept:(record_cleartext_accept ~mode)
    ~record_accept_error:(fun error ->
      Transport_metrics.record_http_accept_error ~mode ~error)
    ~record_closed:(fun () -> Transport_metrics.record_http_connection_closed ~mode)
    ~on_stop:mark_stopped
    (fun ~conn_sw client_addr connection ->
      match
        Server_connection_socket.prepare connection (fun () ->
          Server_connection_socket.await_first_bytes connection)
      with
      | None -> not_prepared ~listener_tag client_addr sent_nothing
      | Some () ->
        serve_h1_connection
          ~sw:conn_sw
          ~request_handler
          client_addr
          (Server_connection_socket.socket connection))
;;

exception Request_without_header_block

(* RFC 9113 §8.4 deprecates server push and browsers stopped accepting it, so
   no H2 connection advertises it. [read_buffer_size] stays the library's
   16384: h2 sizes the DATA frames it writes by that value until the peer
   announces a MAX_FRAME_SIZE, and Chrome, curl and [H2_eio.Client] never do,
   so a larger value would make them drop the connection (#49940). *)
let h2_config () =
  { H2.Config.default with
    enable_server_push = false
  ; max_concurrent_streams = Int32.of_int (H2_response_limits.max_concurrent_streams ())
  ; initial_window_size = Int32.of_int (H2_response_limits.initial_window_size ())
  }
;;

let serve_h2_connection
      ~clock
      ?(streams = Server_h2_stream_registry.create
          ~clock
          ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
          ())
      ?(resources = Http_h2_response_ledger.create
          ~max_pending_bytes:(H2_response_limits.max_pending_bytes ()))
      ~sw
      ~h2_request_handler
      ~h2_error_handler
      client_addr
      flow
  =
  let frames =
    Server_h2_frame_tap.wrap
      ~on_peer_reset:(fun stream_id ->
        Server_h2_stream_registry.peer_reset streams ~stream_id)
      ~on_reset_sent:(fun stream_id ->
        Server_h2_stream_registry.reset_sent streams ~stream_id)
      ~on_response_end:(fun stream_id ->
        Server_h2_stream_registry.response_ended streams ~stream_id)
      flow
  in
  let request_scope, publish_scope = Eio.Promise.create () in
  Eio.Fiber.first
    (fun () ->
      Eio.Switch.run (fun request_sw ->
        Eio.Promise.resolve publish_scope request_sw;
        Eio.Fiber.await_cancel ()))
    (fun () ->
      let request_sw = Eio.Promise.await request_scope in
      let config = h2_config () in
      H2_eio.Server.create_connection_handler ~sw ~config
        ~request_handler:(fun addr reqd ->
          match Server_h2_frame_tap.request_stream frames with
          | Some stream_id ->
            Server_h2_stream_registry.dispatch streams ~sw:request_sw ~stream_id reqd
              (fun stream_end ->
                let stream_sw = Http_h2_stream.Stream_end.switch stream_end in
                Http_h2_response_ledger.with_request resources ~sw:stream_sw
                  (fun () ->
                    try
                      with_request_lane
                        (Http_h2_stream.Stream_end.request stream_end).meth
                        (fun () -> h2_request_handler ~stream_end addr reqd)
                    with
                    | Eio.Cancel.Cancelled _ as exn -> raise exn
                    | exn ->
                      Http_h2_stream.reset ~stream_sw reqd (Http_h2_stream.Raised exn)))
          | None -> Http_h2_stream.report reqd Request_without_header_block)
        ~error_handler:h2_error_handler client_addr (Server_h2_frame_tap.socket frames))
;;

let serve_h2 ~sw ~clock ~socket ~addr_label ~h2_request_handler ~h2_error_handler =
  let resources = shared_h2_resources () in
  let mode = "h2" in
  let listener_tag = Printf.sprintf "%s %s" mode addr_label in
  let mark_stopped = register_listener_lifecycle ~sw ~mode in
  Log.Server.info "[%s] h2c mode activated (MASC_USE_H2=1)" listener_tag;
  run_accept_loop
    ~sw
    ~clock
    ~socket
    ~listener_tag
    ~record_accept:(record_cleartext_accept ~mode)
    ~record_accept_error:(fun error ->
      Transport_metrics.record_http_accept_error ~mode ~error)
    ~record_closed:(fun () -> Transport_metrics.record_http_connection_closed ~mode)
    ~on_stop:mark_stopped
    (fun ~conn_sw client_addr connection ->
      match
        Server_connection_socket.prepare connection (fun () ->
          Server_connection_socket.await_first_bytes connection)
      with
      | None -> not_prepared ~listener_tag client_addr sent_nothing
      | Some () ->
        serve_h2_connection
          ~clock
          ~resources
          ~sw:conn_sw
          ~h2_request_handler
          ~h2_error_handler
          client_addr
          (Server_connection_socket.socket connection))
;;

(** Accept loop with automatic HTTP/1.1 vs HTTP/2 detection.
    Detection suspends until the stream identifies a protocol. The returned
    socket replays the inspected prefix to httpun-eio or h2-eio. *)
let serve_auto ~sw ~clock ~socket ~addr_label ~request_handler ~h2_request_handler ~h2_error_handler =
  let resources = shared_h2_resources () in
  let mode = "auto" in
  let listener_tag = Printf.sprintf "%s %s" mode addr_label in
  let mark_stopped = register_listener_lifecycle ~sw ~mode in
  Log.Server.info "[%s] HTTP auto-detect mode: HTTP/1.1 + HTTP/2 h2c on same port"
    listener_tag;
  let h2_count = Atomic.make 0 in
  let h1_count = Atomic.make 0 in
  run_accept_loop
    ~sw
    ~clock
    ~socket
    ~listener_tag
    ~record_accept:(record_cleartext_accept ~mode)
    ~record_accept_error:(fun error ->
      Transport_metrics.record_http_accept_error ~mode ~error)
    ~record_closed:(fun () -> Transport_metrics.record_http_connection_closed ~mode)
    ~on_stop:(fun () ->
      Log.Server.info "[%s] stats: h2=%d h1=%d"
        listener_tag (Atomic.get h2_count) (Atomic.get h1_count);
      mark_stopped ())
    (fun ~conn_sw client_addr connection ->
      match
        Server_connection_socket.prepare connection (fun () ->
          Http_protocol_detect.detect (Server_connection_socket.socket connection))
      with
      | None -> not_prepared ~listener_tag client_addr "sent no request line or HTTP/2 preface"
      | Some (Ok (Http_protocol_detect.Http2, detected_flow)) ->
        ignore (Atomic.fetch_and_add h2_count 1);
        serve_h2_connection
          ~clock
          ~resources
          ~sw:conn_sw
          ~h2_request_handler
          ~h2_error_handler
          client_addr
          detected_flow
      | Some (Ok (Http_protocol_detect.Http1, detected_flow)) ->
        ignore (Atomic.fetch_and_add h1_count 1);
        serve_h1_connection ~sw:conn_sw ~request_handler client_addr detected_flow
      | Some (Error msg) ->
        Log.Misc.debug "[%s] protocol detect skipped: %s" listener_tag msg)
;;

(* {1 HTTPS listener (RFC-0512 D6)} *)

let https_listener_of_env ~base_path ~bind_host =
  match Env_config.Transport.https_port () with
  | None -> Ok None
  | Some https_port ->
    (match Ptime.of_float_s (Unix.gettimeofday ()) with
     | None -> Error "the clock is not a representable time"
     | Some now ->
       (match
          Server_tls_material.load_or_generate
            ~now
            ~base_path
            ~bind_host
            ~cert_file:(Env_config.Transport.tls_cert_file ())
            ~key_file:(Env_config.Transport.tls_key_file ())
        with
        | Error error -> Error (Server_tls_material.error_to_string error)
        | Ok material ->
          (match Server_tls_material.tls_config material with
           | Error reason -> Error reason
           | Ok tls ->
             Https_listener_metrics.configure
               ~port:https_port
               ~certificate:
                 { Https_listener_metrics.source = material.source
                 ; not_after = material.not_after
                 };
             Ok (Some { https_port; tls; certificate_source = material.source }))))
;;

let listen_https_socket ~sw ~net ~address ~config https =
  match https with
  | None -> None
  | Some listener ->
    (match listen_socket ~sw ~net ~address { config with Http.port = listener.https_port } with
     | socket -> Some (listener, socket)
     | exception (Eio.Cancel.Cancelled _ as e) -> raise e
     | exception exn ->
       let error = Printexc.to_string exn in
       Https_listener_metrics.record_bind_failure ~error;
       Log.Server.error
         "[tls %s:%d] bind failed, HTTPS stays off until the next boot: %s"
         config.Http.host
         listener.https_port
         error;
       None)
;;

let handshake_failed ~listener_tag client_addr reason =
  Https_listener_metrics.record_handshake_failure ();
  Log.Http.debug
    "[%s] TLS handshake with %s ended: %s"
    listener_tag
    (Format.asprintf "%a" Eio.Net.Sockaddr.pp client_addr)
    reason
;;

let serve_tls ~sw ~clock ~socket ~addr_label ~tls ~request_handler ~h2_request_handler ~h2_error_handler =
  let resources = shared_h2_resources () in
  let listener_tag = Printf.sprintf "tls %s" addr_label in
  Https_listener_metrics.record_started ();
  Eio.Switch.on_release sw Https_listener_metrics.record_stopped;
  Log.Server.info "[%s] HTTPS: TLS 1.3, ALPN h2 and http/1.1" listener_tag;
  run_accept_loop
    ~sw
    ~clock
    ~socket
    ~listener_tag
    ~record_accept:(fun latency_s ->
      Https_listener_metrics.record_accept ();
      Transport_metrics.record_http_accept_latency ~mode:"tls" latency_s)
    ~record_accept_error:(fun error -> Https_listener_metrics.record_accept_error ~error)
    ~record_closed:Https_listener_metrics.record_connection_closed
    ~on_stop:Https_listener_metrics.record_stopped
    (fun ~conn_sw client_addr connection ->
      match
        Server_connection_socket.prepare connection (fun () ->
          Tls_eio.server_of_flow tls (Server_connection_socket.socket connection))
      with
      | exception Tls_eio.Tls_alert alert ->
        handshake_failed ~listener_tag client_addr
          (Printf.sprintf "alert %s" (Tls.Packet.alert_type_to_string alert))
      | exception Tls_eio.Tls_failure failure ->
        handshake_failed ~listener_tag client_addr
          (Format.asprintf "%a" Tls.Engine.pp_failure failure)
      | exception End_of_file ->
        handshake_failed ~listener_tag client_addr "peer closed before the handshake completed"
      | None ->
        handshake_failed ~listener_tag client_addr
          (Printf.sprintf
             "not completed within %.0fs"
             Server_connection_socket.preparation_bound_s)
      | Some session ->
        (match Tls_eio.epoch session with
         | Error () ->
           handshake_failed ~listener_tag client_addr "no active session after the handshake"
         | Ok epoch ->
           let socket =
             Tls_stream_socket.wrap session ~on_send_shutdown:(fun () ->
               Server_connection_socket.send_side_closed connection)
           in
           (match epoch.Tls.Core.alpn_protocol with
            | Some protocol when String.equal protocol Server_tls_material.alpn_h2 ->
              Https_listener_metrics.record_negotiated Alpn_h2;
              serve_h2_connection
                ~clock
                ~resources
                ~sw:conn_sw
                ~h2_request_handler
                ~h2_error_handler
                client_addr
                socket
            | Some protocol when String.equal protocol Server_tls_material.alpn_http1 ->
              Https_listener_metrics.record_negotiated Alpn_http1;
              serve_h1_connection ~sw:conn_sw ~request_handler client_addr socket
            | None ->
              Https_listener_metrics.record_negotiated Alpn_none;
              serve_h1_connection ~sw:conn_sw ~request_handler client_addr socket
            | Some protocol ->
              (* The library settles only on a protocol the configuration
                 offered, so this is a library fault, not a client choice. *)
              handshake_failed ~listener_tag client_addr
                (Printf.sprintf "ALPN %S was not offered" protocol))))
;;
