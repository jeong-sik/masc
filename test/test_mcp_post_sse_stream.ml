(* A tools/call POST for a streaming tool answers over SSE on the real HTTP/1
   route: the prime frame, the result as one [message] event, then the end of
   the response. A reading client sees the same bytes whether or not a frame
   waits for the socket; [test_server_sse_response] checks the wait. A call
   cancelled with the runtime switch still ends its response. *)

let protocol_version = "2025-11-25"
let request_timeout_s = 5.0
let streaming_tool = "masc_status"
let result_text = "post-sse-result"

exception Test_finished
exception Runtime_stopped

let with_server env ~handler body =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let socket =
      Eio.Net.listen ~reuse_addr:true ~backlog:8 ~sw (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "expected a TCP listener"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Server_bootstrap_http.serve ~sw ~clock ~socket ~addr_label:"POST SSE test"
        ~request_handler:(fun _addr (reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
          handler reqd.Gluten.Reqd.reqd);
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () -> body ~port)))
;;

let tools_call_body =
  Yojson.Safe.to_string
    (`Assoc
        [ "jsonrpc", `String "2.0"
        ; "id", `Int 1
        ; "method", `String "tools/call"
        ; "params", `Assoc [ "name", `String streaming_tool; "arguments", `Assoc [] ]
        ])
;;

let answer : Yojson.Safe.t =
  `Assoc
    [ "jsonrpc", `String "2.0"
    ; "id", `Int 1
    ; ( "result"
      , `Assoc [ "content", `List [ `Assoc [ "type", `String "text"; "text", `String result_text ] ] ] )
    ]
;;

let contains = String_util.contains_substring

(* A workspace and an MCP session for one test, removed afterwards. *)
let with_session f =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let session_id = "post-sse-" ^ string_of_int (Random.bits ()) in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  Server_mcp_transport_http.remember_protocol_version session_id protocol_version;
  Fun.protect
    ~finally:(fun () ->
      Server_mcp_transport_http.forget_mcp_session session_id;
      ignore (Masc.Session.McpSessionStore.remove session_id);
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> f ~workspace ~session_id)
;;

(* The POST route over [runtime], with every auth check admitting. *)
let post_handler ~workspace (runtime : Server_mcp_transport_http.runtime) =
  let authority =
    match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority
    | Error `Malformed -> Alcotest.fail "fixture authority"
  in
  let admit ~base_path:_ _request = Ok () in
  let deps : Server_mcp_transport_http.deps =
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
    Server_request_authority.with_current authority (fun () ->
      Server_mcp_transport_http.handle_post_mcp ~deps request reqd)
;;

let runtime_on ~sw ~workspace env ~handle : Server_mcp_transport_http.runtime =
  { base_path = workspace
  ; sw
  ; clock = Eio.Stdenv.clock env
  ; tool_allowed_in_profile = (fun _ _ -> true)
  ; handle_request =
      (fun ?profile:_ ?mcp_session_id:_ ?otel_mcp_protocol_version:_
           ?otel_transport_context:_ ?auth_token:_ ?internal_keeper_runtime:_ _ -> handle ())
  ; clear_resource_subscriptions_for_session = (fun _ -> ())
  }
;;

let post_tools_call env ~port ~session_id =
  let url = Printf.sprintf "http://127.0.0.1:%d/mcp" port in
  Masc_http_client.post_response_sync ~clock:(Eio.Stdenv.clock env)
    ~timeout_sec:request_timeout_s ~url
    ~headers:
      [ "Content-Type", "application/json"
      ; "Accept", "application/json, text/event-stream"
      ; "Mcp-Session-Id", session_id
      ; "MCP-Protocol-Version", protocol_version
      ]
    ~body:tools_call_body ()
;;

let check_sse_response (response : Masc_http_client.response) =
  Alcotest.(check int) "status" 200 response.status;
  Alcotest.(check bool) "an SSE response" true
    (List.exists
       (fun (name, value) ->
          String.lowercase_ascii name = "content-type" && contains value "text/event-stream")
       response.headers);
  Alcotest.(check bool) "the prime frame came first" true
    (String.starts_with ~prefix:(Server_mcp_transport_http_headers.sse_prime_event ())
       response.body)
;;

let test_tools_call_post_streams_and_ends env =
  with_session (fun ~workspace ~session_id ->
    (* The route forks its keepalive fiber on the runtime switch; failing the
       switch at the end stops it instead of waiting out its interval. *)
    match
      Eio.Switch.run (fun sw ->
        let runtime = runtime_on ~sw ~workspace env ~handle:(fun () -> answer) in
        with_server env ~handler:(post_handler ~workspace runtime) (fun ~port ->
          match post_tools_call env ~port ~session_id with
          | Error detail -> Alcotest.failf "the streaming POST did not end: %s" detail
          | Ok response ->
            check_sse_response response;
            Alcotest.(check bool) "the result is a message event" true
              (contains response.body "event: message" && contains response.body result_text));
        Eio.Switch.fail sw Test_finished)
    with
    | () -> Alcotest.fail "the failed switch returned normally"
    | exception Test_finished -> ())
;;

(* The runtime switch is cancelled while the tool runs. The call's fiber is
   cancelled with it, and the response still ends: the client reads the
   prime frame and the end of the stream, not an open response until its
   own timeout. *)
let test_a_cancelled_call_ends_its_stream env =
  with_session (fun ~workspace ~session_id ->
    Eio.Switch.run (fun outer ->
      let runtime_switch, publish_runtime_switch = Eio.Promise.create () in
      Eio.Fiber.fork ~sw:outer (fun () ->
        match
          Eio.Switch.run (fun sw ->
            Eio.Promise.resolve publish_runtime_switch sw;
            Eio.Fiber.await_cancel ())
        with
        | () -> ()
        | exception Runtime_stopped -> ());
      let sw = Eio.Promise.await runtime_switch in
      let dispatched, mark_dispatched = Eio.Promise.create () in
      let runtime =
        runtime_on ~sw ~workspace env ~handle:(fun () ->
          Eio.Promise.resolve mark_dispatched ();
          Eio.Fiber.await_cancel ())
      in
      with_server env ~handler:(post_handler ~workspace runtime) (fun ~port ->
        Eio.Fiber.both
          (fun () ->
            Eio.Promise.await dispatched;
            Eio.Switch.fail sw Runtime_stopped)
          (fun () ->
            match post_tools_call env ~port ~session_id with
            | Error detail -> Alcotest.failf "the cancelled call left its stream open: %s" detail
            | Ok response ->
              check_sse_response response;
              Alcotest.(check bool) "no result was written" false
                (contains response.body "event: message")))))
;;

let () =
  Alcotest.run
    "Mcp_post_sse_stream"
    [ ( "tools/call"
      , [ Alcotest.test_case "a streaming tool answers over SSE and the response ends" `Quick
            (fun () -> Eio_main.run test_tools_call_post_streams_and_ends)
        ; Alcotest.test_case "a call cancelled with the runtime switch ends its stream" `Quick
            (fun () -> Eio_main.run test_a_cancelled_call_ends_its_stream)
        ] )
    ]
;;
