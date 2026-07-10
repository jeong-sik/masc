(** HTTP serving layer for MASC MCP server bootstrap.
    Handles socket creation, accept loops, and protocol detection
    (HTTP/1.1 via httpun-eio, HTTP/2 h2c via h2-eio, or auto-detect). *)

module Http = Http_server_eio

let make_http_config ~host ~port : Http.config =
  let config = { Http.default_config with port; host } in
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

let listen_socket ~sw ~net (config : Http.config) =
  let ip =
    match Ipaddr.of_string config.host with
    | Ok addr -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets addr)
    | Error _ -> Eio.Net.Ipaddr.V4.loopback
  in
  let addr = `Tcp (ip, config.port) in
  Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.listen_backlog addr
;;

let print_startup_banner
      ~(config : Http.config)
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
  Printf.printf "   GET  /api/v1/activity/graph → Activity graph snapshot\n%!";
  Printf.printf "   GET  /health → Health check\n%!";
  if Masc_grpc_server.is_enabled ()
  then
    Printf.printf
      "   gRPC :%d → Workspace + grpc.health.v1.Health + reflection\n%!"
      (Masc_grpc_server.configured_port ());
  if Transport_metrics.ws_enabled ()
  then
    (match Env_config.Transport.use_h2 () with
     | Env_config.Transport.H2_only ->
       Printf.printf
         "   GET  /ws → discovery only (WebSocket upgrade unavailable in H2-only mode)\n%!"
     | Env_config.Transport.H1_only
     | Env_config.Transport.Auto
     | Env_config.Transport.Unknown_h2_mode _ ->
       Printf.printf
         "   GET  /ws → authenticated same-origin WebSocket upgrade or discovery\n%!");
  if Server_webrtc_transport.is_enabled ()
  then Printf.printf "   POST /webrtc/offer, /webrtc/answer → WebRTC signaling\n%!"
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

let on_connection_release conn_sw ~mode ~listener_tag flow =
  with_cleanups_on_release ~sw:conn_sw
    [
      (fun () -> Transport_metrics.record_http_connection_closed ~mode);
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

let serve ~sw ~clock ~socket ~addr_label ~request_handler =
  let mode = "h1" in
  (* Stable listener identity. Mirrors the [h1 host:port]/[h2 host:port]
     tag introduced in http_server_eio.ml / http_server_h2.ml so error
     log lines name *which* listener emitted them when a process runs
     multiple HTTP servers. *)
  let listener_tag = Printf.sprintf "%s %s" mode addr_label in
  let mark_stopped = register_listener_lifecycle ~sw ~mode in
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  let rec accept_loop backoff_s =
    try
      let accept_start = Unix.gettimeofday () in
      let flow, client_addr = Eio.Net.accept ~sw socket in
      disable_nagle flow;
      let accept_latency = Unix.gettimeofday () -. accept_start in
      Transport_metrics.record_http_accept ~mode;
      Transport_metrics.record_http_accept_latency ~mode accept_latency;
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          on_connection_release conn_sw ~mode ~listener_tag flow;
          try
            let conn_handler =
              Httpun_eio.Server.create_connection_handler
                ~sw:conn_sw
                ~request_handler:(fun client_addr -> request_handler client_addr)
                ~error_handler:(fun _client_addr ?request:_ error respond ->
                  let msg =
                    match error with
                    | `Exn exn -> Printexc.to_string exn
                    | `Bad_request -> "Bad request"
                    | `Bad_gateway -> "Bad gateway"
                    | `Internal_server_error -> "Internal server error"
                  in
                  let body =
                    respond (Httpun.Headers.of_list [ "content-type", "text/plain" ])
                  in
                  Httpun.Body.Writer.write_string body msg;
                  Httpun.Body.Writer.close body)
            in
            conn_handler client_addr flow
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Misc.error "[%s] connection error: %s"
              listener_tag (Printexc.to_string exn)));
      accept_loop 0.05
    with
    | Eio.Cancel.Cancelled _ as e ->
      mark_stopped ();
      raise e
    | exn ->
      if is_cancelled exn
      then mark_stopped ()
      else (
        let error = Printexc.to_string exn in
        Transport_metrics.record_http_accept_error ~mode ~error;
        Log.Misc.error "[%s] accept error: %s" listener_tag error;
        (try Eio.Time.sleep clock backoff_s with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "[%s] backoff sleep: %s"
             listener_tag (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5)))
  in
  accept_loop 0.05
;;

let serve_h2 ~sw ~clock ~socket ~addr_label ~h2_request_handler ~h2_error_handler =
  let mode = "h2" in
  let listener_tag = Printf.sprintf "%s %s" mode addr_label in
  let mark_stopped = register_listener_lifecycle ~sw ~mode in
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  Log.Server.info "[%s] h2c mode activated (MASC_USE_H2=1)" listener_tag;
  let rec accept_loop backoff_s =
    try
      let accept_start = Unix.gettimeofday () in
      let flow, client_addr = Eio.Net.accept ~sw socket in
      disable_nagle flow;
      let accept_latency = Unix.gettimeofday () -. accept_start in
      Transport_metrics.record_http_accept ~mode;
      Transport_metrics.record_http_accept_latency ~mode accept_latency;
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          on_connection_release conn_sw ~mode ~listener_tag flow;
          try
            H2_eio.Server.create_connection_handler
              ~sw:conn_sw
              ~request_handler:h2_request_handler
              ~error_handler:h2_error_handler
              client_addr
              flow
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Misc.error "[%s] connection error: %s"
              listener_tag (Printexc.to_string exn)));
      accept_loop 0.05
    with
    | Eio.Cancel.Cancelled _ as e ->
      mark_stopped ();
      raise e
    | exn ->
      if is_cancelled exn
      then mark_stopped ()
      else (
        let error = Printexc.to_string exn in
        Transport_metrics.record_http_accept_error ~mode ~error;
        Log.Misc.error "[%s] accept error: %s" listener_tag error;
        (try Eio.Time.sleep clock backoff_s with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "[%s] backoff sleep: %s"
             listener_tag (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5)))
  in
  accept_loop 0.05
;;

(** Accept loop with automatic HTTP/1.1 vs HTTP/2 detection.
    Each connection is peeked (MSG_PEEK) to inspect the first bytes
    before dispatching to httpun-eio or h2-eio.  The peek is
    non-destructive, so both libraries read the socket normally. *)
let serve_auto ~sw ~clock ~socket ~addr_label ~request_handler ~h2_request_handler ~h2_error_handler =
  let mode = "auto" in
  let listener_tag = Printf.sprintf "%s %s" mode addr_label in
  let mark_stopped = register_listener_lifecycle ~sw ~mode in
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  Log.Server.info "[%s] HTTP auto-detect mode: HTTP/1.1 + HTTP/2 h2c on same port"
    listener_tag;
  let h2_count = Atomic.make 0 in
  let h1_count = Atomic.make 0 in
  let stats_logged = Atomic.make false in
  let log_stats () =
    Log.Server.info "[%s] stats: h2=%d h1=%d"
      listener_tag
      (Atomic.get h2_count)
      (Atomic.get h1_count)
  in
  let rec accept_loop backoff_s =
    try
      let accept_start = Unix.gettimeofday () in
      let flow, client_addr = Eio.Net.accept ~sw socket in
      disable_nagle flow;
      let accept_latency = Unix.gettimeofday () -. accept_start in
      Transport_metrics.record_http_accept ~mode;
      Transport_metrics.record_http_accept_latency ~mode accept_latency;
      Eio.Fiber.fork ~sw (fun () ->
        Eio.Switch.run (fun conn_sw ->
          on_connection_release conn_sw ~mode ~listener_tag flow;
          try
            match Http_protocol_detect.detect flow with
            | Ok Http_protocol_detect.Http2 ->
              ignore (Atomic.fetch_and_add h2_count 1);
              H2_eio.Server.create_connection_handler
                ~sw:conn_sw
                ~request_handler:h2_request_handler
                ~error_handler:h2_error_handler
                client_addr
                flow
            | Ok Http_protocol_detect.Http1 ->
              ignore (Atomic.fetch_and_add h1_count 1);
              let conn_handler =
                Httpun_eio.Server.create_connection_handler
                  ~sw:conn_sw
                  ~request_handler:(fun client_addr -> request_handler client_addr)
                  ~error_handler:(fun _client_addr ?request:_ error respond ->
                    let msg =
                      match error with
                      | `Exn exn -> Printexc.to_string exn
                      | `Bad_request -> "Bad request"
                      | `Bad_gateway -> "Bad gateway"
                      | `Internal_server_error -> "Internal server error"
                    in
                    let body =
                      respond (Httpun.Headers.of_list [ "content-type", "text/plain" ])
                    in
                    Httpun.Body.Writer.write_string body msg;
                    Httpun.Body.Writer.close body)
              in
              conn_handler client_addr flow
            | Error msg ->
              Log.Misc.debug "[%s] protocol detect skipped: %s" listener_tag msg
          with
          | Eio.Cancel.Cancelled _ as e -> raise e
          | exn ->
            Log.Misc.error "[%s] connection error: %s"
              listener_tag (Printexc.to_string exn)));
      accept_loop 0.05
    with
    | Eio.Cancel.Cancelled _ as e ->
      if Atomic.compare_and_set stats_logged false true then log_stats ();
      mark_stopped ();
      raise e
    | exn ->
      if is_cancelled exn
      then (
        if Atomic.compare_and_set stats_logged false true then log_stats ();
        mark_stopped ())
      else (
        let error = Printexc.to_string exn in
        Transport_metrics.record_http_accept_error ~mode ~error;
        Log.Misc.error "[%s] accept error: %s" listener_tag error;
        (try Eio.Time.sleep clock backoff_s with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "[%s] backoff sleep: %s"
             listener_tag (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5)))
  in
  accept_loop 0.05
;;
