(** HTTP serving layer for MASC MCP server bootstrap.
    Handles socket creation, accept loops, and protocol detection
    (HTTP/1.1 via httpun-eio, HTTP/2 h2c via h2-eio, or auto-detect). *)

module Http = Http_server_eio

let make_http_config ~host ~port : Http.config =
  let config = { Http.default_config with port; host } in
  Unix.putenv "MASC_HOST" config.host;
  Unix.putenv "MASC_HTTP_PORT" (string_of_int config.port);
  (match Sys.getenv_opt "MASC_HTTP_BASE_URL" with
  | Some existing when String.trim existing <> "" -> ()
  | _ ->
      let advertised_host =
        if Server_auth.is_unspecified_host config.host then
          Masc_network_defaults.masc_http_default_host
        else config.host
      in
      Unix.putenv "MASC_HTTP_BASE_URL"
        (Printf.sprintf "http://%s:%d" advertised_host config.port));
  config

let listen_socket ~sw ~net (config : Http.config) =
  let ip =
    match Ipaddr.of_string config.host with
    | Ok addr -> Eio.Net.Ipaddr.of_raw (Ipaddr.to_octets addr)
    | Error _ -> Eio.Net.Ipaddr.V4.loopback
  in
  let addr = `Tcp (ip, config.port) in
  Eio.Net.listen net ~sw ~reuse_addr:true ~backlog:config.max_connections addr

let print_startup_banner ~(config : Http.config) ~resolved_base ~base_path
    ~masc_dir ~path_diagnostics =
  Printf.printf "MASC MCP Server listening on http://%s:%d\n%!" config.host
    config.port;
  Printf.printf "   Base path: %s\n%!" resolved_base;
  if resolved_base <> base_path then
    Printf.printf "   Base path (input): %s\n%!" base_path;
  Printf.printf "   MASC dir: %s\n%!" masc_dir;
  List.iter (fun line -> Printf.printf "%s\n%!" line)
    (Server_base_path_diagnostics.startup_lines path_diagnostics);
  Printf.printf "   GET  /mcp → SSE stream (notifications)\n%!";
  Printf.printf
    "   POST /mcp → JSON-RPC (Accept: application/json, text/event-stream)\n\
     %!";
  Printf.printf "   DELETE /mcp → Session termination\n%!";
  Printf.printf
    "   POST /graphql → GraphQL (read-only)\n%!";
  Printf.printf "   GET  /api/v1/activity/events → Activity replay API\n%!";
  Printf.printf "   GET  /api/v1/activity/graph → Activity graph snapshot\n%!";
  Printf.printf "   GET  /health → Health check\n%!";
  Printf.printf
    "   Compatibility (deprecated): GET /sse, POST /messages → use /mcp\n%!";
  if Masc_grpc_server.is_enabled () then
    Printf.printf
      "   gRPC :%d → Coordination + grpc.health.v1.Health + reflection\n%!"
      (Masc_grpc_server.configured_port ());
  if Server_ws_standalone.is_enabled () then
    Printf.printf
      "   GET  /ws → WebSocket discovery (standalone ws://127.0.0.1:%d/)\n%!"
      (Server_ws_standalone.configured_port ());
  if Server_webrtc_transport.is_enabled () then
    Printf.printf
      "   POST /webrtc/offer, /webrtc/answer → WebRTC signaling\n%!"

let serve ~sw ~clock ~socket ~request_handler =
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              Eio.Switch.on_release conn_sw (fun () ->
                  try Eio.Flow.close flow
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn -> Log.Misc.warn "flow close: %s" (Printexc.to_string exn));
              try
                let conn_handler =
                  Httpun_eio.Server.create_connection_handler ~sw:conn_sw
                    ~request_handler:(fun client_addr ->
                      request_handler client_addr)
                    ~error_handler:(fun _client_addr ?request:_ error respond ->
                      let msg =
                        match error with
                        | `Exn exn -> Printexc.to_string exn
                        | `Bad_request -> "Bad request"
                        | `Bad_gateway -> "Bad gateway"
                        | `Internal_server_error ->
                            "Internal server error"
                      in
                      let body =
                        respond
                          (Httpun.Headers.of_list
                             [ ("content-type", "text/plain") ])
                      in
                      Httpun.Body.Writer.write_string body msg;
                      Httpun.Body.Writer.close body)
                in
                conn_handler client_addr flow
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "Connection error: %s"
                  (Printexc.to_string exn)))
      ;
      accept_loop 0.05
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then ()
      else begin
        Log.Misc.error "Accept error: %s" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn -> Log.Misc.warn "backoff sleep: %s" (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

let serve_h2 ~sw ~clock ~socket ~h2_request_handler ~h2_error_handler =
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  Log.Server.info "HTTP/2 h2c mode activated (MASC_USE_H2=1)";
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              Eio.Switch.on_release conn_sw (fun () ->
                  try Eio.Flow.close flow
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn -> Log.Misc.warn "[h2] flow close: %s" (Printexc.to_string exn));
              try
                H2_eio.Server.create_connection_handler ~sw:conn_sw
                  ~request_handler:h2_request_handler
                  ~error_handler:h2_error_handler
                  client_addr
                  flow
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "[h2] Connection error: %s"
                  (Printexc.to_string exn)));
      accept_loop 0.05
    with Eio.Cancel.Cancelled _ as e -> raise e | exn ->
      if is_cancelled exn then ()
      else begin
        Log.Misc.error "[h2] Accept error: %s" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn -> Log.Misc.warn "[h2] backoff sleep: %s" (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05

(** Accept loop with automatic HTTP/1.1 vs HTTP/2 detection.
    Each connection is peeked (MSG_PEEK) to inspect the first bytes
    before dispatching to httpun-eio or h2-eio.  The peek is
    non-destructive, so both libraries read the socket normally. *)
let serve_auto ~sw ~clock ~socket ~request_handler ~h2_request_handler
    ~h2_error_handler =
  let is_cancelled exn =
    match exn with
    | Eio.Cancel.Cancelled _ -> true
    | _ -> false
  in
  Log.Server.info "HTTP auto-detect mode: HTTP/1.1 + HTTP/2 h2c on same port";
  let h2_count = Atomic.make 0 in
  let h1_count = Atomic.make 0 in
  let stats_logged = Atomic.make false in
  let rec accept_loop backoff_s =
    try
      let flow, client_addr = Eio.Net.accept ~sw socket in
      Eio.Fiber.fork ~sw (fun () ->
          Eio.Switch.run (fun conn_sw ->
              Eio.Switch.on_release conn_sw (fun () ->
                  try Eio.Flow.close flow
                  with
                  | Eio.Cancel.Cancelled _ as e -> raise e
                  | exn ->
                    Log.Misc.warn "[auto] flow close: %s"
                      (Printexc.to_string exn));
              try
                match Http_protocol_detect.detect flow with
                | Ok Http_protocol_detect.Http2 ->
                  ignore (Atomic.fetch_and_add h2_count 1);
                  H2_eio.Server.create_connection_handler ~sw:conn_sw
                    ~request_handler:h2_request_handler
                    ~error_handler:h2_error_handler
                    client_addr
                    flow
                | Ok Http_protocol_detect.Http1 ->
                  ignore (Atomic.fetch_and_add h1_count 1);
                  let conn_handler =
                    Httpun_eio.Server.create_connection_handler ~sw:conn_sw
                      ~request_handler:(fun client_addr ->
                        request_handler client_addr)
                      ~error_handler:
                        (fun _client_addr ?request:_ error respond ->
                        let msg =
                          match error with
                          | `Exn exn -> Printexc.to_string exn
                          | `Bad_request -> "Bad request"
                          | `Bad_gateway -> "Bad gateway"
                          | `Internal_server_error -> "Internal server error"
                        in
                        let body =
                          respond
                            (Httpun.Headers.of_list
                               [ ("content-type", "text/plain") ])
                        in
                        Httpun.Body.Writer.write_string body msg;
                        Httpun.Body.Writer.close body)
                  in
                  conn_handler client_addr flow
                | Error msg ->
                  Log.Misc.debug "[auto] protocol detect skipped: %s" msg
              with
              | Eio.Cancel.Cancelled _ as e -> raise e
              | exn ->
                Log.Misc.error "[auto] Connection error: %s"
                  (Printexc.to_string exn)));
      accept_loop 0.05
    with
    | Eio.Cancel.Cancelled _ as e ->
      if Atomic.compare_and_set stats_logged false true then
        Log.Server.info "[auto] stats: h2=%d h1=%d"
          (Atomic.get h2_count) (Atomic.get h1_count);
      raise e
    | exn ->
      if is_cancelled exn then begin
        if Atomic.compare_and_set stats_logged false true then
          Log.Server.info "[auto] stats: h2=%d h1=%d"
            (Atomic.get h2_count) (Atomic.get h1_count)
      end
      else begin
        Log.Misc.error "[auto] Accept error: %s" (Printexc.to_string exn);
        (try Eio.Time.sleep clock backoff_s
         with
         | Eio.Cancel.Cancelled _ as e -> raise e
         | exn ->
           Log.Misc.warn "[auto] backoff sleep: %s"
             (Printexc.to_string exn));
        accept_loop (Float.min 2.0 (backoff_s *. 1.5))
      end
  in
  accept_loop 0.05
