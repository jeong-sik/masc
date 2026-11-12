(* Exercise the real HTTP/1 routes through their server-side stream cleanup.
   A streaming response with no body length must reach EOF when its writer is
   closed, or a client cannot reconnect until its idle timeout. *)

let with_server env ~handler body =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let socket =
      Eio.Net.listen ~reuse_addr:true ~backlog:8 ~sw (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port = match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "expected a TCP listener"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label:"SSE EOF test"
        ~request_handler:(fun _addr (reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
          handler reqd.Gluten.Reqd.reqd);
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () -> body ~port)))

let identity workspace : Masc.Tui_decode.server_identity =
  let module Decode = Masc.Tui_decode in
  { sid_version = "test"
  ; sid_binary_commit = "test"
  ; sid_binary_commit_age_s = None
  ; sid_runtime_instance_id = None
  ; sid_base_path = Decode.Canonical_path.of_path (Unix.realpath workspace)
  ; sid_masc_root = Decode.Canonical_path.of_path
      (Unix.realpath (Filename.concat workspace ".masc"))
  ; sid_executable_in_worktree = None
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None; sid_operator_action = None
  }

exception Stop_dashboard_route

(* Cancel the route's own switch after its first frame while the HTTP server
   remains alive. This tests route cleanup, not a server socket shutdown. *)
let test_execute_output_route_eof env =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Masc.Server_startup_state.snapshot () in
  let transport_env =
    [ "MASC_HTTP_AUTH_STRICT", "false"
    ; "MASC_HOST", "127.0.0.1"
    ; "MASC_HTTP_BASE_URL", "http://127.0.0.1:8935" ]
  in
  let previous_env = List.map (fun (name, _) -> name, Sys.getenv_opt name) transport_env in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Masc.Server_startup_state.For_testing.restore previous_startup;
      List.iter (fun (name, value) -> match value with
        | Some value -> Unix.putenv name value
        | None -> Unix.unsetenv name) previous_env;
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
      List.iter (fun (name, value) -> Unix.putenv name value) transport_env;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
      Server_auth.For_testing.restore_server_state (Some state);
      Masc.Server_startup_state.reset ();
      Result.get_ok (Masc.Server_startup_state.mark_state_ready ());
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let route, publish_route = Eio.Promise.create () in
        let stop, signal_stop = Eio.Promise.create () in
        let stopped, signal_stopped = Eio.Promise.create () in
        Eio.Fiber.fork ~sw (fun () ->
          (try Eio.Switch.run (fun route_sw ->
             let router = Server_routes_http_routes_dashboard.add_routes ~sw:route_sw ~clock
                 (Masc.Http_server_eio.Router.create ()) in
             Eio.Promise.resolve publish_route (fun reqd ->
               Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd));
             Eio.Promise.await stop;
             Eio.Switch.fail route_sw Stop_dashboard_route)
           with Stop_dashboard_route -> ());
          Eio.Promise.resolve signal_stopped ());
        let handler = Eio.Promise.await route in
        with_server env ~handler (fun ~port ->
          let got_frame = ref false in
          let result =
            try Eio.Time.with_timeout_exn clock 3. (fun () ->
              Masc_tui_http.observe_execute_output_stream ~clock
                ~expected_workspace:(identity workspace) ~host:"127.0.0.1" ~port
                ~keeper:"eof-test" ~on_chunk:(fun _ ->
                  if not !got_frame then begin
                    got_frame := true;
                    Eio.Promise.resolve signal_stop ()
                  end))
            with Eio.Time.Timeout ->
              Alcotest.failf "execute EOF timed out (frame=%b, route_stopped=%b)"
                !got_frame (Option.is_some (Eio.Promise.peek stopped))
          in
          Alcotest.(check bool) "the real route sent a frame" true !got_frame;
          Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await stopped);
          match result with
          | Ok () -> ()
          | Error _ -> Alcotest.fail "execute stream did not end cleanly")))

(* The TUI's log stream client against the real route. The route admits a
   stream only under the Observer instance the request names: the instance
   the server serves reaches a frame, any other is refused before one. *)
let test_log_stream_names_its_observer_instance env =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Masc.Server_startup_state.snapshot () in
  let transport_env =
    [ "MASC_HTTP_AUTH_STRICT", "false"
    ; "MASC_HOST", "127.0.0.1"
    ; "MASC_HTTP_BASE_URL", "http://127.0.0.1:8935" ]
  in
  let previous_env = List.map (fun (name, _) -> name, Sys.getenv_opt name) transport_env in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Masc.Server_startup_state.For_testing.restore previous_startup;
      List.iter (fun (name, value) -> match value with
        | Some value -> Unix.putenv name value
        | None -> Unix.unsetenv name) previous_env;
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
      List.iter (fun (name, value) -> Unix.putenv name value) transport_env;
      let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
      Server_auth.For_testing.restore_server_state (Some state);
      Masc.Server_startup_state.reset ();
      Result.get_ok (Masc.Server_startup_state.mark_state_ready ());
      (* The first frame is a page of the ring, and an empty page is not sent. *)
      Log.emit Log.Warn ~module_name:"tui-log-stream-instance-test" "an entry to page";
      let clock = Eio.Stdenv.clock env in
      try
        Eio.Switch.run (fun route_sw ->
          let router =
            Server_routes_http_routes_log_stream.add_routes ~sw:route_sw ~clock
              (Masc.Http_server_eio.Router.create ())
          in
          let handler reqd =
            Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd)
              (Masc.Http_reqd.of_httpun reqd)
          in
          with_server env ~handler (fun ~port ->
            let follow instance =
              let frame, got_frame = Eio.Promise.create () in
              try
                Eio.Time.with_timeout_exn clock 3. (fun () ->
                  Eio.Fiber.first
                    (fun () ->
                      `Ended
                        (Masc_tui_http.observe_system_log_stream ~clock ~host:"127.0.0.1"
                           ~port ~instance ~limit:10
                           ~on_chunk:(fun _ -> ignore (Eio.Promise.try_resolve got_frame ()))
                           ()))
                    (fun () -> Eio.Promise.await frame; `Frame))
              with Eio.Time.Timeout ->
                Alcotest.failf "the log stream named %s and neither ended nor sent a frame"
                  instance
            in
            let serving =
              Server_observer_scope.instance_id (Masc.Mcp_server.workspace_scope state)
            in
            (match follow serving with
             | `Frame -> ()
             | `Ended why -> Alcotest.failf "the served instance was refused: %s" why);
            match follow "another-instance" with
            | `Ended _ -> ()
            | `Frame -> Alcotest.fail "a stream that named another instance got a frame");
          Eio.Switch.fail route_sw Stop_dashboard_route)
      with Stop_dashboard_route -> ())

let admit ~base_path:_ _request = Ok ()

(* The real presence route, served with a runtime on [runtime_sw], so its
   supervisor owns the response (RFC-0493 §3.2). *)
let presence_handler env ~workspace ~runtime_sw =
  let authority =
    match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority
    | Error `Malformed -> Alcotest.fail "fixture authority"
  in
  let runtime : Server_mcp_transport_http_types.runtime =
    { base_path = workspace
    ; sw = runtime_sw
    ; clock = Eio.Stdenv.clock env
    ; tool_allowed_in_profile = (fun _ _ -> true)
    ; handle_request =
        (fun ?profile:_ ?mcp_session_id:_ ?otel_mcp_protocol_version:_
             ?otel_transport_context:_ ?auth_token:_ ?internal_keeper_runtime:_ _ -> `Null)
    ; clear_resource_subscriptions_for_session = (fun _ -> ())
    }
  in
  let deps : Server_mcp_transport_http_types.deps =
    { get_origin = (fun _ -> "")
    ; cors_headers = (fun _ -> [])
    ; auth_token_from_request = (fun _ -> None)
    ; is_ready = (fun () -> true)
    ; get_runtime_result = (fun () -> Ok runtime)
    ; get_base_path = (fun () -> workspace)
    ; get_server_state = (fun () -> None)
    ; verify_mcp_auth = admit
    ; verify_mcp_observer_stream_auth = admit
    ; verify_operator_mcp_auth = admit
    ; verify_seat_mcp_auth = admit
    }
  in
  fun reqd ->
    let request = Httpun.Reqd.request reqd in
    let reqd = Masc.Http_reqd.of_httpun reqd in
    Server_request_authority.with_current authority (fun () ->
      Server_mcp_transport_http_agui.handle_presence_events ~deps request reqd)

let with_presence_session prefix body =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let raw_session_id = prefix ^ "-" ^ string_of_int (Random.bits ()) in
  let session_id = "presence:" ^ raw_session_id in
  let auth = Masc_test_deps.make_sse_auth workspace prefix in
  let token = Option.get auth.Masc.Sse.token in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:raw_session_id ());
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> Server_mcp_transport_http_conn.stop_sse_session session_id);
      ignore (Masc.Session.McpSessionStore.remove raw_session_id);
      ignore (Masc.Session.McpSessionStore.remove session_id);
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> body ~workspace ~raw_session_id ~session_id ~token)

(* A presence stream is closed by the real session stop path after its prime
   frame. The HTTP server itself stays up while the client waits for EOF. *)
let test_presence_route_eof env =
  with_presence_session "presence-eof" (fun ~workspace ~raw_session_id ~session_id ~token ->
    Eio.Switch.run (fun runtime_sw ->
      let handler = presence_handler env ~workspace ~runtime_sw in
      with_server env ~handler (fun ~port ->
        let clock = Eio.Stdenv.clock env in
        let got_frame = ref false in
        let url = Printf.sprintf "http://127.0.0.1:%d/events/presence" port in
        let result =
          try Eio.Time.with_timeout_exn clock 3. (fun () ->
            Masc_http_client.get_stream ~clock ~idle_timeout_sec:10. ~url
              ~headers:[ "Accept", "text/event-stream"; "Mcp-Session-Id", raw_session_id
                       ; "Authorization", "Bearer " ^ token ]
              ~on_response:(fun ~status ~headers:_ ->
                Alcotest.(check int) "presence opens" 200 status)
              ~on_chunk:(fun _ ->
                if not !got_frame then begin
                  got_frame := true;
                  Server_mcp_transport_http_conn.stop_sse_session session_id
                end) ())
          with Eio.Time.Timeout ->
            Alcotest.failf "presence EOF timed out (frame=%b, session_active=%b)"
              !got_frame (Server_mcp_transport_http_conn.is_active_sse_session session_id)
        in
        Alcotest.(check bool) "the real route sent a frame" true !got_frame;
        match result with
        | Ok (Masc_http_client.Pool.Streamed _) -> ()
        | Ok (Masc_http_client.Pool.Buffered _) -> Alcotest.fail "presence was buffered"
        | Error detail -> Alcotest.failf "presence stream failed: %s" detail)))

let unread_stream_bound_s = 5.0

(* The request arrives on an in-memory connection whose writes nobody reads,
   so the prime frame never reaches a socket. The handler still returns at
   once: the drain pump sends the prime under the supervisor. A stop then
   cancels that waiting send, and the runtime switch can finish. Before, the
   handler itself waited on the prime for [sse_stalled_after_s] (90 s). *)
let test_presence_prime_waits_in_the_pump env =
  with_presence_session "presence-unread" (fun ~workspace ~raw_session_id ~session_id ~token ->
    let request =
      Printf.sprintf
        "GET /events/presence HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nAccept: text/event-stream\r\nMcp-Session-Id: %s\r\nAuthorization: Bearer %s\r\n\r\n"
        raw_session_id token
    in
    let len = String.length request in
    match
      Eio.Time.with_timeout (Eio.Stdenv.clock env) unread_stream_bound_s (fun () ->
        Eio.Switch.run (fun runtime_sw ->
          let connection =
            Httpun.Server_connection.create (presence_handler env ~workspace ~runtime_sw)
          in
          ignore
            (Httpun.Server_connection.read connection
               (Bigstringaf.of_string request ~off:0 ~len) ~off:0 ~len
             : int);
          Alcotest.(check bool) "the handler returned with the stream open" true
            (Server_mcp_transport_http_conn.is_active_sse_session session_id);
          Server_mcp_transport_http_conn.stop_sse_session session_id);
        Ok ())
    with
    | Ok () ->
      Alcotest.(check bool) "the stream left the registry" false
        (Server_mcp_transport_http_conn.is_active_sse_session session_id)
    | Error `Timeout ->
      Alcotest.failf "an unread presence stream held its handler or supervisor past %.0f s"
        unread_stream_bound_s)

let () =
  let case name test = Alcotest.test_case name `Quick (fun () -> Eio_main.run test) in
  Alcotest.run "Tui_sse_eof"
    [ "real routes", [ case "execute cleanup ends response" test_execute_output_route_eof
                     ; case "log stream names its Observer instance"
                         test_log_stream_names_its_observer_instance
                     ; case "presence stop ends response" test_presence_route_eof
                     ; case "an unread presence prime waits in the pump"
                         test_presence_prime_waits_in_the_pump ] ]
