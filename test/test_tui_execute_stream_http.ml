(* The Terminal tab's request for a Keeper's Execute output stream, over a real
   loopback socket against a server that answers the way the dashboard route
   and its workspace check do: a stream that carries the workspace receipt, a
   stream that does not, and a refusal.

   The route and its check are not run here; what is run is the terminal's
   side: the URL it asks for, which responses it reads, and which it refuses
   before it reads a byte. *)

module EO = Dashboard_execute_output
module Http = Masc_tui_http

let receipt_name = "x-masc-workspace-read"
let receipt = receipt_name, "matched-v1"

let identity : Masc.Tui_decode.server_identity =
  let module Decode = Masc.Tui_decode in
  { sid_version = "test"
  ; sid_binary_commit = "test"
  ; sid_binary_commit_age_s = None; sid_runtime_instance_id = None
  ; sid_base_path = Decode.Canonical_path.of_path "/owned-workspace"
  ; sid_masc_root = Decode.Canonical_path.of_path "/owned-workspace/.masc"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None; sid_operator_action = None
  }
;;

(* What the route writes first on a connection to a Keeper that has run one
   command. *)
let first_frames () =
  EO.reset_for_testing ();
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:1 ~task_id:None ~command:"run";
  EO.append_stream_chunk ~keeper_name:"alpha" ~stream_id:1 ~stream:`Stdout "one\n";
  match EO.subscribe ~keeper_name:"alpha" with
  | None -> Alcotest.fail "the server gave no subscriber"
  | Some subscriber ->
    Fun.protect
      ~finally:(fun () -> EO.unsubscribe subscriber)
      (fun () -> "retry: 1500\n\n" ^ EO.sse_frame (EO.initial_event_json subscriber))
;;

(* The headers the route sets on its stream, and whatever receipts the test
   adds to them. The route keeps its connection alive and ends a stream only
   when the server stops; this one closes the connection after its frames, so a
   client reads to the end without waiting out its idle limit. *)
let stream_response ?(status = `OK) ?(content_types = [ "text/event-stream" ])
    ~receipts frames reqd =
  let headers =
    Httpun.Headers.of_list
      (List.map (fun value -> "content-type", value) content_types
       @ [ "cache-control", "private, no-store"
       ; "connection", "close"
       ; "x-accel-buffering", "no"
       ]
       @ receipts)
  in
  if status = `No_content then
    Httpun.Reqd.respond_with_string reqd (Httpun.Response.create ~headers status) ""
  else begin
    let body = Httpun.Reqd.respond_with_streaming reqd (Httpun.Response.create ~headers status) in
    List.iter (fun frame -> Httpun.Body.Writer.write_string body frame) frames;
    Httpun.Body.Writer.close body
  end
;;

let json_response ~status body reqd =
  let headers =
    Httpun.Headers.of_list
      [ "content-type", "application/json"
      ; "content-length", string_of_int (String.length body)
      ]
  in
  Httpun.Reqd.respond_with_string reqd (Httpun.Response.create ~headers status) body
;;

(* The accept loop of the real server on a loopback port, with [handler] in
   place of its router. *)
let with_server env ~handler body =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let socket =
      Eio.Net.listen
        ~reuse_addr:true
        ~backlog:8
        ~sw
        (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0))
    in
    let port =
      match Eio.Net.listening_addr socket with
      | `Tcp (_, port) -> port
      | `Unix _ -> Alcotest.fail "the test listens on TCP"
    in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      Server_bootstrap_http.serve
        ~sw
        ~clock
        ~socket
        ~addr_label:"execute stream test"
        ~request_handler:(fun _addr (gluten_reqd : Httpun.Reqd.t Gluten.Reqd.t) ->
          handler gluten_reqd.Gluten.Reqd.reqd);
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () -> body ~port)))
;;

let observe env ~port ?(keeper = "alpha") ~on_chunk () =
  Http.observe_execute_output_stream
    ~clock:(Eio.Stdenv.clock env)
    ~expected_workspace:identity
    ~host:"127.0.0.1"
    ~port
    ~keeper
    ~on_chunk
;;

let with_env test () = Eio_main.run (fun env -> test env)

let test_an_attested_stream_is_read_to_its_end env =
  let frames = first_frames () in
  let target = ref "" in
  let handler reqd =
    target := (Httpun.Reqd.request reqd).Httpun.Request.target;
    stream_response ~receipts:[ receipt ] [ frames ] reqd
  in
  with_server env ~handler (fun ~port ->
    let received = Buffer.create 256 in
    (match observe env ~port ~on_chunk:(Buffer.add_string received) () with
     | Ok () -> ()
     | Error (Http.Execute_http_refused { status; detail }) ->
       Alcotest.failf "the stream was refused (%d): %s" status detail
     | Error (Http.Execute_unattested { status; detail }) ->
       Alcotest.failf "the stream was unattested (%d): %s" status detail
     | Error (Http.Execute_invalid_response { status; detail }) ->
       Alcotest.failf "the stream response was invalid (%d): %s" status detail
     | Error (Http.Execute_transport_failed detail) ->
       Alcotest.failf "the transport failed: %s" detail);
    Alcotest.(check string) "the bytes the server wrote" frames (Buffer.contents received);
    let uri = Uri.of_string !target in
    Alcotest.(check string) "the route" "/api/v1/dashboard/execute-output/alpha" (Uri.path uri);
    Alcotest.(check (option string))
      "bound to the base path"
      (Some "/owned-workspace")
      (Uri.get_query_param uri "expected_base_path");
    Alcotest.(check (option string))
      "and to the masc root"
      (Some "/owned-workspace/.masc")
      (Uri.get_query_param uri "expected_masc_root"))
;;

(* A server that does not know the two fields answers for whichever workspace
   it holds, and says nothing about it. The stream is not read. *)
let test_a_stream_without_the_receipt_is_refused_before_a_byte_is_read env =
  List.iter
    (fun (label, receipts) ->
       let handler = stream_response ~receipts [ first_frames () ] in
       with_server env ~handler (fun ~port ->
         let chunks = ref 0 in
         match observe env ~port ~on_chunk:(fun _ -> incr chunks) () with
         | Error (Http.Execute_unattested { status; detail }) ->
           Alcotest.(check int) (label ^ ": the status is the stream's") 200 status;
           Alcotest.(check bool)
             (label ^ ": it says the read was not attested")
             true
             (String_util.contains_substring detail "attest");
           Alcotest.(check int) (label ^ ": nothing was read") 0 !chunks
         | Error (Http.Execute_http_refused { status; detail }) ->
           Alcotest.failf "%s: ordinary HTTP refusal %d: %s" label status detail
         | Error (Http.Execute_invalid_response { status; detail }) ->
           Alcotest.failf "%s: invalid response %d: %s" label status detail
         | Error (Http.Execute_transport_failed detail) ->
           Alcotest.failf "%s: the transport failed instead: %s" label detail
         | Ok () -> Alcotest.failf "%s: the stream was accepted" label))
    [ "no receipt", []
    ; "another value", [ receipt_name, "matched-v0" ]
    ; "the receipt twice", [ receipt; receipt ]
    ]
;;

let test_execute_rejects_invalid_sse_responses_before_reading env =
  let cases =
    [ "JSON body", `OK, [ "application/json" ], 200
    ; "missing media type", `OK, [], 200
    ; "duplicate media types", `OK, [ "text/event-stream"; "text/event-stream" ], 200
    ; "no content", `No_content, [ "text/event-stream" ], 204
    ]
  in
  List.iter (fun (label, status, content_types, expected_status) ->
    let handler = stream_response ~status ~content_types ~receipts:[ receipt ]
        [ "data: {}\n\n" ] in
    with_server env ~handler (fun ~port ->
      let chunks = ref 0 in
      (match observe env ~port ~on_chunk:(fun _ -> incr chunks) () with
       | Error (Http.Execute_invalid_response { status; _ }) ->
         Alcotest.(check int) (label ^ ": status") expected_status status
       | Error _ -> Alcotest.failf "%s: wrong error" label
       | Ok () -> Alcotest.failf "%s: response was accepted" label);
      Alcotest.(check int) (label ^ ": no body chunks") 0 !chunks)) cases
;;

let test_a_workspace_mismatch_is_refused_with_its_status env =
  let handler =
    json_response
      ~status:`Conflict
      {|{"error_code":"workspace_precondition_failed","error":"workspace precondition failed"}|}
  in
  with_server env ~handler (fun ~port ->
    let chunks = ref 0 in
    match observe env ~port ~on_chunk:(fun _ -> incr chunks) () with
    | Error (Http.Execute_http_refused { status; detail }) ->
      Alcotest.(check int) "the status" 409 status;
      Alcotest.(check bool)
        "it names the stream that was refused"
        true
        (String_util.contains_substring detail "Execute output stream");
      Alcotest.(check int) "nothing was read" 0 !chunks
    | Error (Http.Execute_unattested { status; detail }) ->
      Alcotest.failf "unexpected unattested status %d: %s" status detail
    | Error (Http.Execute_invalid_response { status; detail }) ->
      Alcotest.failf "unexpected invalid response %d: %s" status detail
    | Error (Http.Execute_transport_failed detail) ->
      Alcotest.failf "the transport failed instead: %s" detail
    | Ok () -> Alcotest.fail "a refusal was read as a stream")
;;

let test_a_keeper_name_is_encoded_in_the_path env =
  let target = ref "" in
  let handler reqd =
    target := (Httpun.Reqd.request reqd).Httpun.Request.target;
    json_response ~status:`Not_found "{}" reqd
  in
  with_server env ~handler (fun ~port ->
    ignore
      (observe env ~port ~keeper:"a b" ~on_chunk:ignore () : (unit, Http.execute_output_stream_error) result);
    Alcotest.(check string)
      "the path"
      "/api/v1/dashboard/execute-output/a%20b"
      (List.hd (String.split_on_char '?' !target)))
;;

let test_goal_timeline_query_preserves_the_requested_id env =
  let observed = ref None in
  let handler reqd =
    let request = Httpun.Reqd.request reqd in
    let requested = Masc.Server_utils.query_param request "goal_id" in
    observed := Some request;
    let received = Option.value ~default:"missing" requested in
    let returned = if String.equal received "mismatch" then "other" else received in
    let body = Yojson.Safe.to_string (`Assoc [
      "goal", `Assoc ["id", `String returned];
      "approval_queue_state", `Assoc ["state", `String "ready"];
      "timeline", `List [`Assoc ["ts", `String "t"; "kind", `String "goal";
        "lane", `String "goal"; "title", `String "event";
        "summary", `String received; "severity", `String "ok"]]
    ]) in
    let headers = Httpun.Headers.of_list [receipt; "content-type", "application/json";
      "content-length", string_of_int (String.length body)] in
    Httpun.Reqd.respond_with_string reqd (Httpun.Response.create ~headers `OK) body
  in
  with_server env ~handler (fun ~port ->
    Eio.Switch.run (fun sw ->
      Eio_context.with_test_env ~net:(Eio.Stdenv.net env) ~clock:(Eio.Stdenv.clock env)
        ~mono_clock:(Eio.Stdenv.mono_clock env) ~sw (fun () ->
          Http.start_io_domain ~sw ~env;
          List.iter (fun goal_id ->
            observed := None;
            let result = Masc_tui_workspace_read.with_binding ~host:"127.0.0.1" ~port
                ~expected:identity ~proof:Masc_tui_workspace_read.Request_precondition
                (fun () -> Http.fetch_goal_timeline ~host:"127.0.0.1" ~port ~goal_id) in
            (match result with
             | Ok (Masc.Tui_decode.Goal_timeline_ready [event]) ->
                 Alcotest.(check string) "the event belongs to the requested Goal" goal_id event.gt_summary
             | Ok _ -> Alcotest.fail "the ready timeline was not returned"
             | Error detail -> Alcotest.fail detail);
            let request = Option.get !observed in
            Alcotest.(check (option string)) "the server receives the exact ID"
              (Some goal_id) (Masc.Server_utils.query_param request "goal_id");
            Alcotest.(check (option string)) "the server receives the workspace base"
              (Some "/owned-workspace") (Masc.Server_utils.query_param request "expected_base_path");
            Alcotest.(check (option string)) "the server receives the workspace root"
              (Some "/owned-workspace/.masc") (Masc.Server_utils.query_param request "expected_masc_root"))
            ["goal"; "g+1"; "g&1"; "g,1"; "g%20"; "g#1"; "\194\160g\194\160"];
          let mismatched = Masc_tui_workspace_read.with_binding ~host:"127.0.0.1" ~port
              ~expected:identity ~proof:Masc_tui_workspace_read.Request_precondition
              (fun () -> Http.fetch_goal_timeline ~host:"127.0.0.1" ~port ~goal_id:"mismatch") in
          Alcotest.(check bool) "a different Goal response is refused" true (Result.is_error mismatched))))
;;

(* A raw peer can advertise a body longer than it sends, something the HTTP
   server helper deliberately prevents. It also observes the client closing
   its socket after a timeout, refusal, or cancellation. *)
let with_raw_peer env ~status ~attest ~truncate body =
  let clock = Eio.Stdenv.clock env in
  Eio.Switch.run (fun sw ->
    let listener =
      Eio.Net.listen ~reuse_addr:true ~backlog:4 ~sw (Eio.Stdenv.net env)
        (`Tcp (Eio.Net.Ipaddr.V4.loopback, 0)) in
    let port = match Eio.Net.listening_addr listener with
      | `Tcp (_, port) -> port | `Unix _ -> assert false in
    let closed = ref false and writes = ref 0 in
    Eio.Fiber.fork_daemon ~sw (fun () ->
      (* Pool establishment uses a separate TCP reachability probe first. *)
      let rec accept_request () =
        let flow, _ = Eio.Net.accept ~sw listener in
        let input = Eio.Buf_read.of_flow ~max_size:65536 flow in
        match Eio.Buf_read.line input with
        | _ -> flow, input
        | exception End_of_file -> Eio.Flow.close flow; accept_request () in
      let flow, input = accept_request () in
      let rec skip_headers () =
        if not (String.equal (Eio.Buf_read.line input) "") then skip_headers () in
      skip_headers ();
      Eio.Flow.copy_string
        (Printf.sprintf "HTTP/1.1 %d Test\r\nContent-Length: 1000000\r\n%s\r\n"
          status (if attest then "x-masc-workspace-read: matched-v1\r\nContent-Type: text/event-stream\r\n" else "")) flow;
      if truncate then (
        Eio.Flow.copy_string "partial" flow;
        Eio.Flow.close flow
      ) else (
        Eio.Fiber.fork_daemon ~sw (fun () ->
          (try
             while true do
               Eio.Flow.copy_string "x" flow;
               incr writes;
               Eio.Time.sleep clock 0.02
             done
           with
           | Eio.Cancel.Cancelled _ as exn -> raise exn
           | Eio.Io _ | Unix.Unix_error _ -> ());
          `Stop_daemon);
        (try ignore (Eio.Buf_read.take_all input); closed := true with
         | Eio.Io (Eio.Net.E (Eio.Net.Connection_reset _), _)
         | Unix.Unix_error ((Unix.ECONNRESET | Unix.EPIPE), _, _) -> closed := true));
      `Stop_daemon);
    Eio.Switch.run (fun pool_sw ->
      Masc_http_client.with_scoped_pool ~sw:pool_sw ~env (fun () ->
        body ~port ~closed ~writes)))
;;

let wait_for_peer_close env closed =
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 2.0 (fun () ->
    while not !closed do Eio.Time.sleep (Eio.Stdenv.clock env) 0.01 done)
;;

let observe_with_refusal_timeout env ~port ~on_chunk =
  Http.observe_execute_output_stream_with_refusal_timeout
    ~refusal_body_timeout_s:0.15
    ~clock:(Eio.Stdenv.clock env) ~expected_workspace:identity
    ~host:"127.0.0.1" ~port ~keeper:"alpha" ~on_chunk
;;

let test_refusal_body_disconnect_keeps_the_status env =
  with_raw_peer env ~status:401 ~attest:false ~truncate:true (fun ~port ~closed:_ ~writes:_ ->
    let chunks = ref 0 in
    match observe_with_refusal_timeout env ~port ~on_chunk:(fun _ -> incr chunks) with
    | Error (Http.Execute_http_refused { status = 401; detail }) ->
      Alcotest.(check bool) "the body read failed" true
        (String_util.contains_substring detail "refusal body unreadable");
      Alcotest.(check int) "no refusal body entered the stream" 0 !chunks
    | Error (Http.Execute_http_refused { status; _ }) -> Alcotest.failf "wrong status: %d" status
    | Error (Http.Execute_unattested { status; detail }) ->
      Alcotest.failf "unexpected unattested status %d: %s" status detail
    | Error (Http.Execute_invalid_response { status; detail }) ->
      Alcotest.failf "unexpected invalid response %d: %s" status detail
    | Error (Http.Execute_transport_failed detail) -> Alcotest.failf "lost status: %s" detail
    | Ok () -> Alcotest.fail "a refusal was accepted")
;;

let test_dribbling_refusal_has_a_whole_body_deadline env =
  List.iter (fun status ->
    with_raw_peer env ~status ~attest:false ~truncate:false (fun ~port ~closed ~writes ->
      let chunks = ref 0 in
      let started = Eio.Time.now (Eio.Stdenv.clock env) in
      let result = observe_with_refusal_timeout env ~port ~on_chunk:(fun _ -> incr chunks) in
      let elapsed = Eio.Time.now (Eio.Stdenv.clock env) -. started in
      (match result with
       | Error (Http.Execute_http_refused { status = received; detail }) ->
         Alcotest.(check int) "status retained" status received;
         Alcotest.(check bool) "deadline explained" true
           (String_util.contains_substring detail "did not finish in time")
       | Error (Http.Execute_unattested { status; detail }) ->
         Alcotest.failf "unexpected unattested status %d: %s" status detail
       | Error (Http.Execute_invalid_response { status; detail }) ->
         Alcotest.failf "unexpected invalid response %d: %s" status detail
       | Error (Http.Execute_transport_failed detail) -> Alcotest.failf "lost status: %s" detail
       | Ok () -> Alcotest.fail "a refusal was accepted");
      Alcotest.(check bool) "the body was still making progress" true (!writes >= 2);
      Alcotest.(check bool) "the deadline was armed" true (elapsed >= 0.12);
      Alcotest.(check int) "no refusal body entered the stream" 0 !chunks;
      wait_for_peer_close env closed))
    [ 401; 408; 425; 429; 503 ]
;;

let test_the_refusal_deadline_does_not_end_a_successful_stream env =
  with_raw_peer env ~status:200 ~attest:true ~truncate:false (fun ~port ~closed ~writes ->
    let chunks = ref 0 in
    let clock = Eio.Stdenv.clock env in
    (match
       try `Result (Eio.Time.with_timeout_exn clock 0.35 (fun () ->
         observe_with_refusal_timeout env ~port ~on_chunk:(fun _ -> incr chunks)))
       with Eio.Time.Timeout -> `Timeout
     with
     | `Timeout -> ()
     | `Result (Ok ()) -> Alcotest.fail "the server did not close the stream"
     | `Result (Error (Http.Execute_http_refused { detail; _ } | Http.Execute_unattested { detail; _ } | Http.Execute_invalid_response { detail; _ } | Http.Execute_transport_failed detail)) ->
       Alcotest.failf "healthy stream ended at refusal deadline: %s" detail);
    Alcotest.(check bool) "stream continued past the refusal deadline" true (!writes >= 5 && !chunks > 0);
    wait_for_peer_close env closed)
;;

let test_cancelling_a_refusal_body_still_cancels_the_request env =
  with_raw_peer env ~status:401 ~attest:false ~truncate:false (fun ~port ~closed ~writes:_ ->
    (match
       try `Result (Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 0.05 (fun () ->
         observe_with_refusal_timeout env ~port ~on_chunk:ignore))
       with Eio.Time.Timeout -> `Timeout
     with
     | `Timeout -> ()
     | `Result (Ok ()) -> Alcotest.fail "a refusal was accepted"
     | `Result (Error (Http.Execute_http_refused _ | Http.Execute_unattested _ | Http.Execute_invalid_response _ | Http.Execute_transport_failed _)) ->
       Alcotest.fail "cancellation was reported as a stream outcome");
    wait_for_peer_close env closed)
;;

let test_observer_rejects_bad_replay_before_delivering_bytes env =
  let requested = Some Sse_wire.{ instance_id = "process-a"; event_id = 50 } in
  let resumed = [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed" ] in
  let cases =
    [ "duplicate instance", None,
      [ "x-masc-sse-instance-id", "process-a"; "X-Masc-Sse-Instance-Id", "process-b"
      ; "x-masc-sse-replay", "fresh" ]
    ; "combined instances", None,
      [ "x-masc-sse-instance-id", "process-a, process-b"; "x-masc-sse-replay", "fresh" ]
    ; "resumed without cursor", None, resumed
    ; "fresh with requested cursor", requested,
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "fresh" ]
    ; "reset with unchanged instance", requested,
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "reset-instance-changed" ]
    ; "reset without requested cursor", None,
      [ "x-masc-sse-instance-id", "process-b"; "x-masc-sse-replay", "reset-instance-changed" ]
    ; "future cursor reset with another instance", requested,
      [ "x-masc-sse-instance-id", "process-b"; "x-masc-sse-replay", "reset-cursor-ahead" ]
    ; "future cursor reset without a cursor", None,
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "reset-cursor-ahead" ]
    ; "resumed with another instance", requested,
      [ "x-masc-sse-instance-id", "process-b"; "x-masc-sse-replay", "resumed" ]
    ; "gap does not pass cursor", requested,
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed-after-gap"
      ; "x-masc-sse-replay-missed-through", "50" ]
    ] in
  List.iter (fun (label, cursor, headers) ->
    with_server env ~handler:(stream_response ~receipts:(receipt :: headers) [ "data: {}\n\n" ]) (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~on_identity:(fun _ -> ()) ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root
          ~host:"127.0.0.1" ~port ~session_id:"observer-test" ~cursor
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      (match result with
       | Error (Http.Invalid_handshake _) -> ()
       | Error (Http.Retry_without_cursor (_, detail)) ->
           Alcotest.failf "%s: unexpectedly retried: %s" label detail
       | Error (Http.Transport_failed detail) -> Alcotest.failf "%s: transport: %s" label detail
       | Error (Http.Http_refused { status; _ }) -> Alcotest.failf "%s: HTTP %d" label status
       | Ok () -> Alcotest.failf "%s: accepted" label);
      Alcotest.(check int) (label ^ ": no open callback") 0 !opens;
      Alcotest.(check int) (label ^ ": no body callback") 0 !chunks)) cases
;;

let test_observer_retries_without_cursor env =
  let requested = Sse_wire.{ instance_id = "process-a"; event_id = 50 } in
  let cases =
    [ "unadvertised replay", []
    ; "scoped request reported unscoped",
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "reset-unscoped-cursor" ]
    ; "incomplete replay metadata", [ "x-masc-sse-instance-id", "process-a" ]
    ; "duplicate instance",
      [ "x-masc-sse-instance-id", "process-a"; "X-Masc-Sse-Instance-Id", "process-b"
      ; "x-masc-sse-replay", "resumed" ]
    ] in
  List.iter (fun (label, headers) ->
    with_server env ~handler:(stream_response ~receipts:(receipt :: headers) [ "data: {}\n\n" ]) (fun ~port ->
      let identities = ref 0 and opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~on_identity:(fun _ -> incr identities)
          ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root
          ~host:"127.0.0.1" ~port ~session_id:"observer-test" ~cursor:(Some requested)
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      (match result with
       | Error (Http.Retry_without_cursor (cursor, _)) ->
           Alcotest.(check bool) (label ^ ": retry names requested cursor") true (cursor = requested)
       | Error (Http.Invalid_handshake detail | Http.Transport_failed detail) ->
           Alcotest.failf "%s: %s" label detail
       | Error (Http.Http_refused { status; _ }) -> Alcotest.failf "%s: HTTP %d" label status
       | Ok () -> Alcotest.failf "%s: accepted" label);
      Alcotest.(check int) (label ^ ": no identity callback") 0 !identities;
      Alcotest.(check int) (label ^ ": no open callback") 0 !opens;
      Alcotest.(check int) (label ^ ": no body callback") 0 !chunks)) cases;
  with_server env ~handler:(stream_response ~receipts:[] [ "data: {}\n\n" ]) (fun ~port ->
    let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
        ~on_identity:ignore ~expected_base_path:identity.sid_base_path
        ~expected_masc_root:identity.sid_masc_root
        ~host:"127.0.0.1" ~port ~session_id:"observer-test" ~cursor:(Some requested)
        ~on_open:ignore ~on_chunk:ignore in
    match result with
    | Error (Http.Invalid_handshake _) -> ()
    | Error (Http.Retry_without_cursor _) -> Alcotest.fail "unattested workspace discarded the cursor"
    | Error (Http.Transport_failed detail) -> Alcotest.failf "transport: %s" detail
    | Error (Http.Http_refused { status; _ }) -> Alcotest.failf "HTTP %d" status
    | Ok () -> Alcotest.fail "unattested workspace was accepted")
;;

let test_observer_identity_requires_scoped_admission env =
  let scoped = ["x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "fresh"] in
  let identity_headers = Sse_wire.observer_identity_headers
      {version="0.66.0"; binary_commit=Some "abc123"} in
  let cases =
    [ "valid", receipt :: scoped @ identity_headers, true, true
    ; "unadvertised", receipt :: scoped, true, false
    ; "missing workspace receipt", scoped @ identity_headers, false, false
    ; "missing scope epoch", receipt :: identity_headers, false, false
    ; "duplicate identity", receipt :: scoped @ identity_headers @ identity_headers, false, false
    ; "partial identity", receipt :: scoped @ ["x-masc-observer-identity", "v1"], false, false
    ] in
  List.iter (fun (label, headers, accepted, attested) ->
    with_server env ~handler:(stream_response ~receipts:headers ["data: {}\n\n"]) (fun ~port ->
      let identities = ref [] and opens = ref 0 and chunks = ref 0 and order = ref [] in
      let outcome = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root ~host:"127.0.0.1" ~port ~session_id:"observer-test"
          ~cursor:None ~on_identity:(fun value -> identities := value :: !identities; order := `Identity :: !order)
          ~on_open:(fun _ -> incr opens; order := `Open :: !order)
          ~on_chunk:(fun _ -> incr chunks; order := `Body :: !order) in
      Alcotest.(check bool) (label ^ ": accepted") accepted (Result.is_ok outcome);
      Alcotest.(check bool) (label ^ ": identity callback") attested (!identities <> []);
      Alcotest.(check bool) (label ^ ": open callback") accepted (!opens > 0);
      Alcotest.(check bool) (label ^ ": body callback") accepted (!chunks > 0);
      if attested then Alcotest.(check bool) (label ^ ": identity before open and body") true
          (match List.rev !order with `Identity :: `Open :: `Body :: _ -> true | _ -> false))) cases
;;

let test_observer_accepts_valid_and_unadvertised_live_streams env =
  let requested = Some Sse_wire.{ instance_id = "process-a"; event_id = 50 } in
  List.iter (fun (label, cursor, headers) ->
    with_server env ~handler:(stream_response ~receipts:(receipt :: headers) [ "data: {}\n\n" ]) (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~on_identity:(fun _ -> ()) ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root
          ~host:"127.0.0.1" ~port ~session_id:"observer-test" ~cursor
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      (match result with
       | Ok () -> ()
       | Error (Http.Invalid_handshake detail | Http.Transport_failed detail) ->
           Alcotest.failf "%s: %s" label detail
       | Error (Http.Retry_without_cursor (_, detail)) ->
           Alcotest.failf "%s: unexpectedly retried: %s" label detail
       | Error (Http.Http_refused { status; _ }) -> Alcotest.failf "%s: HTTP %d" label status);
      Alcotest.(check int) (label ^ ": open callback") 1 !opens;
      Alcotest.(check bool) (label ^ ": body delivered") true (!chunks > 0)))
    [ "scoped fresh", None, [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "fresh" ]
    ; "unadvertised live-only", None, []
    ; "resumed", requested, [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed" ]
    ; "resumed after gap", requested,
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "resumed-after-gap"
      ; "x-masc-sse-replay-missed-through", "51" ]
    ; "instance reset", requested,
      [ "x-masc-sse-instance-id", "process-b"; "x-masc-sse-replay", "reset-instance-changed" ]
    ; "future cursor reset", requested,
      [ "x-masc-sse-instance-id", "process-a"; "x-masc-sse-replay", "reset-cursor-ahead" ] ]
;;

(* A 200 response alone does not say which workspace a replacement server
   serves. No observer callback may see its events without the receipt. *)
let test_observer_requires_workspace_receipt env =
  List.iter (fun (label, receipts, accepted) ->
    let target = ref "" in
    let handler reqd =
      target := (Httpun.Reqd.request reqd).target;
      stream_response ~receipts [ "data: {}\n\n" ] reqd
    in
    with_server env ~handler (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~on_identity:(fun _ -> ()) ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root
          ~host:"127.0.0.1" ~port ~session_id:"observer-workspace" ~cursor:None
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      (match accepted, result with
       | true, Ok () | false, Error (Http.Invalid_handshake _) -> ()
       | _ -> Alcotest.failf "%s: wrong observer admission" label);
      Alcotest.(check int) (label ^ ": open only if attested") (if accepted then 1 else 0) !opens;
      Alcotest.(check bool) (label ^ ": bytes only if attested") accepted (!chunks > 0);
      let uri = Uri.of_string !target in
      Alcotest.(check (option string)) (label ^ ": requested base")
        (Some "/owned-workspace") (Uri.get_query_param uri "expected_base_path");
      Alcotest.(check (option string)) (label ^ ": requested root")
        (Some "/owned-workspace/.masc") (Uri.get_query_param uri "expected_masc_root")))
    [ "missing", [], false
    ; "wrong", [ receipt_name, "matched-v0" ], false
    ; "duplicate", [ receipt; receipt ], false
    ; "matched", [ receipt ], true ]
;;

let test_observer_workspace_refusal_is_not_a_session_conflict _env =
  let workspace = {|{"code":"workspace_precondition_failed"}|} in
  let session = {|{"error":"session belongs to another profile"}|} in
  Alcotest.(check bool) "workspace refusal recognized" true
    (Http.observer_workspace_refused ~status:409 ~detail:workspace);
  Alcotest.(check bool) "session conflict stays a session conflict" false
    (Http.observer_workspace_refused ~status:409 ~detail:session);
  Alcotest.(check bool) "the same body at another status is not a workspace refusal" false
    (Http.observer_workspace_refused ~status:404 ~detail:workspace);
  Alcotest.(check bool) "malformed refusal is not a workspace refusal" false
    (Http.observer_workspace_refused ~status:409 ~detail:"{")
;;

(* An HTTP success is not enough to establish an SSE stream. Both long-lived
   readers must reject an invalid response before its bytes reach a decoder. *)
let test_sse_status_and_content_type_gate env =
  let cases =
    [ "plain stream", `OK, [ "text/event-stream" ], true
    ; "case and parameter", `OK, [ "Text/Event-Stream; charset=utf-8" ], true
    ; "quoted comma", `OK, [ "text/event-stream; profile=\"a,b\"" ], true
    ; "missing type", `OK, [], false
    ; "JSON type", `OK, [ "application/json" ], false
    ; "duplicate type", `OK, [ "text/event-stream"; "text/event-stream" ], false
    ; "combined type", `OK, [ "text/event-stream, text/html" ], false
    ; "combined after parameter", `OK, [ "text/event-stream; charset=utf-8, text/html" ], false
    ; "unterminated quoted parameter", `OK, [ "text/event-stream; profile=\"broken" ], false
    ; "created status", `Created, [ "text/event-stream" ], false
    ; "no-content status", `No_content, [], false
    ] in
  List.iter (fun (label, status, content_types, expected_open) ->
    let handler = stream_response ~status ~content_types ~receipts:[ receipt ] [ "data: {}\n\n" ] in
    with_server env ~handler (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let observer = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~on_identity:(fun _ -> ()) ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root
          ~host:"127.0.0.1" ~port ~session_id:"observer-media" ~cursor:None
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      let check_outcome source outcome =
        match expected_open, outcome with
        | true, Ok () | false, Error (Http.Invalid_handshake _) -> ()
        | _ -> Alcotest.failf "%s: %s returned the wrong result" label source in
      check_outcome "observer" observer;
      Alcotest.(check int) (label ^ ": observer open") (if expected_open then 1 else 0) !opens;
      Alcotest.(check bool) (label ^ ": observer body") expected_open (!chunks > 0);
      let fleet_chunks = ref 0 in
      let fleet = Http.observe_fleet_stream ~clock:(Eio.Stdenv.clock env)
          ~expected_workspace:identity ~host:"127.0.0.1" ~port
          ~on_chunk:(fun _ -> incr fleet_chunks) in
      check_outcome "fleet" fleet;
      Alcotest.(check bool) (label ^ ": fleet body") expected_open (!fleet_chunks > 0))) cases
;;

let test_sse_http_refusals_keep_status_and_body env =
  List.iter (fun (status, code) ->
    let body = "fixture refusal" in
    with_server env ~handler:(json_response ~status body) (fun ~port ->
      let chunks = ref 0 and opens = ref 0 in
      let observer = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~on_identity:(fun _ -> ()) ~expected_base_path:identity.sid_base_path ~expected_masc_root:identity.sid_masc_root
          ~host:"127.0.0.1" ~port ~session_id:"observer-refused" ~cursor:None
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      let fleet = Http.observe_fleet_stream ~clock:(Eio.Stdenv.clock env)
          ~expected_workspace:identity ~host:"127.0.0.1" ~port
          ~on_chunk:(fun _ -> incr chunks) in
      let check_refusal source = function
        | Error (Http.Http_refused { status; detail }) ->
            Alcotest.(check int) (source ^ " status") code status;
            Alcotest.(check string) (source ^ " body") body detail
        | _ -> Alcotest.failf "%s did not return an HTTP refusal" source in
      check_refusal "observer" observer;
      check_refusal "fleet" fleet;
      Alcotest.(check int) "no stream opened" 0 !opens;
      Alcotest.(check int) "no refusal body reached a stream decoder" 0 !chunks))
    [ `Unauthorized, 401; `Not_found, 404; `Conflict, 409; `Service_unavailable, 503 ]
;;

(* A peer that ignores the expected-workspace query can still answer 200.
   The body is not usable unless this response carries its own receipt. *)
let test_fleet_requires_workspace_receipt env =
  List.iter (fun (label, receipts, accepted) ->
    with_server env ~handler:(stream_response ~receipts [ "data: {}\n\n" ]) (fun ~port ->
      let chunks = ref 0 in
      let result = Http.observe_fleet_stream ~clock:(Eio.Stdenv.clock env)
          ~expected_workspace:identity ~host:"127.0.0.1" ~port
          ~on_chunk:(fun _ -> incr chunks) in
      (match accepted, result with
       | true, Ok () | false, Error (Http.Invalid_handshake _) -> ()
       | _ -> Alcotest.failf "%s: wrong fleet admission" label);
      Alcotest.(check bool) (label ^ ": body delivered only if attested") accepted (!chunks > 0)))
    [ "matched", [ receipt ], true
    ; "missing", [], false
    ; "wrong", [ receipt_name, "not-matched" ], false
    ; "duplicate", [ receipt; receipt ], false
    ; "case-mixed duplicate", [ receipt; "X-Masc-Workspace-Read", snd receipt ], false
    ; "combined", [ receipt_name, "matched-v1, matched-v1" ], false ]
;;

(* Exercise the actual H1 workspace precondition wrapper and fleet stream
   route together; neither authentication nor a production server is used. *)
let test_fleet_route_attests_its_admitted_workspace env =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let base_path = Unix.realpath workspace in
  let masc_root = Unix.realpath (Filename.concat workspace ".masc") in
  let state = Masc.Mcp_server_eio.For_testing.create_state ~base_path:workspace () in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let hub = Masc.Fleet_stream_hub.create ~on_subscriber_error:(fun _ -> ()) in
      Masc.Fleet_stream_hub.note_degraded hub ~since:10. Masc.Fleet_stream.Scan_failed;
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        let reqd = Masc.Http_reqd.of_httpun reqd in
        Server_auth.with_read_workspace_precondition state
          (fun _ _ reqd ->
             Server_routes_http_routes_fleet_stream.serve ~sw ~clock
               ~subscribe:(Masc.Fleet_stream_hub.subscribe hub)
               ~ping_interval_s:0.1 ~stalled_after_s:2. ~max_queued_events:4 reqd)
          request reqd in
      with_server env ~handler (fun ~port ->
        let exception Headers of int * (string * string) list in
        let get_headers query =
          let url = Printf.sprintf "http://127.0.0.1:%d/api/v1/stream/fleet%s" port query in
          match Masc_http_client.get_stream ~clock ~idle_timeout_sec:3. ~url ~headers:[]
              ~on_response:(fun ~status ~headers -> raise (Headers (status, headers)))
              ~on_chunk:(fun _ -> ()) () with
          | exception Headers (status, headers) -> status, headers
          | _ -> Alcotest.fail "fleet response did not deliver headers" in
        let query base root =
          Uri.add_query_params' (Uri.of_string "")
            [ "expected_base_path", base; "expected_masc_root", root ]
          |> Uri.to_string in
        let receipt_values headers =
          List.filter_map (fun (name, value) ->
            if String.equal (String.lowercase_ascii name) receipt_name then Some value else None)
            headers in
        let status, headers = get_headers (query base_path masc_root) in
        Alcotest.(check int) "matched route opens" 200 status;
        Alcotest.(check (list string)) "matched stream carries its receipt"
          [ snd receipt ] (receipt_values headers);
        let status, headers = get_headers "" in
        Alcotest.(check int) "unbound route opens" 200 status;
        Alcotest.(check (list string)) "unbound stream has no receipt" [] (receipt_values headers);
        let status, headers = get_headers (query "/foreign-workspace" masc_root) in
        Alcotest.(check int) "foreign workspace is refused" 409 status;
        Alcotest.(check (list string)) "refusal has no matched receipt" [] (receipt_values headers);
        let expected : Masc.Tui_decode.server_identity =
          { identity with
            sid_base_path = Masc.Tui_decode.Canonical_path.of_path base_path
          ; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path masc_root
          } in
        let reader = Masc_tui_fleet_stream.create () in
        let exception Snapshot_received in
        (match Http.observe_fleet_stream ~clock ~expected_workspace:expected
             ~host:"127.0.0.1" ~port ~on_chunk:(fun chunk ->
               ignore (Masc_tui_fleet_stream.feed reader chunk : Masc_tui_fleet_stream.step);
               match Masc_tui_fleet_stream.view reader with
               | Masc_tui_fleet_stream.Unavailable _ -> raise Snapshot_received
               | _ -> ()) with
         | exception Snapshot_received -> ()
         | _ -> Alcotest.fail "attested client did not receive the route snapshot");
        Alcotest.(check bool) "the real client decoded the admitted snapshot" true
          (match Masc_tui_fleet_stream.view reader with
           | Masc_tui_fleet_stream.Unavailable { degradation; _ } ->
               degradation.reason = Masc.Fleet_stream.Scan_failed
           | _ -> false))))
;;

(* Exercise the registered HTTP/1 route and its workspace admission wrapper,
   not just [serve], across a same-path workspace replacement. *)
let test_registered_fleet_route_replaces_its_scope env =
  let workspace = Masc_test_deps.setup_test_workspace () in
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Masc.Server_startup_state.snapshot () in
  let transport_env =
    [ "MASC_HTTP_AUTH_STRICT", "false"
    ; "MASC_HOST", "127.0.0.1"
    ; "MASC_HTTP_BASE_URL", "http://127.0.0.1:8935" ]
  in
  let previous_env = List.map (fun (name, _) -> name, Sys.getenv_opt name) transport_env in
  let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Masc.Server_startup_state.For_testing.restore previous_startup;
      List.iter (fun (name, value) ->
        match value with Some value -> Unix.putenv name value | None -> Unix.unsetenv name)
        previous_env;
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () ->
      List.iter (fun (name, value) -> Unix.putenv name value) transport_env;
      Server_auth.For_testing.restore_server_state (Some state);
      Masc.Server_startup_state.reset ();
      Result.get_ok (Masc.Server_startup_state.mark_state_ready ());
      Eio.Switch.run (fun sw ->
        let clock = Eio.Stdenv.clock env in
        let scope = Masc.Mcp_server.workspace_scope state in
        let hub_for scope =
          match Server_routes_http_runtime.fleet_stream_hub_for_scope ~state ~scope with
          | Some hub -> hub
          | None -> Alcotest.fail "the current scope has no fleet hub"
        in
        let old_hub = hub_for scope in
        Masc.Fleet_stream_hub.note_degraded old_hub ~since:10. Masc.Fleet_stream.Scan_failed;
        let router = Server_routes_http_routes_fleet_stream.add_routes ~sw ~clock
            (Masc.Http_server_eio.Router.create ()) in
        let handler reqd =
          Masc.Http_server_eio.Router.dispatch router (Httpun.Reqd.request reqd) (Masc.Http_reqd.of_httpun reqd) in
        with_server env ~handler (fun ~port ->
          let query = Uri.add_query_params' (Uri.of_string "")
              [ "expected_base_path", Unix.realpath workspace
              ; "expected_masc_root", Unix.realpath (Filename.concat workspace ".masc") ]
            |> Uri.to_string in
          let url = Printf.sprintf "http://127.0.0.1:%d%s%s" port
              Masc.Fleet_stream.stream_path query in
          let switched = ref false and attested = ref false in
          let result =
            Eio.Time.with_timeout_exn clock 3.0 (fun () ->
              Masc_http_client.get_stream ~clock ~idle_timeout_sec:2.0 ~url ~headers:[]
                ~on_response:(fun ~status ~headers ->
                  Alcotest.(check int) "the registered route opens" 200 status;
                  attested := List.exists (fun (name, value) ->
                    String.equal (String.lowercase_ascii name) receipt_name
                    && String.equal value (snd receipt)) headers)
                ~on_chunk:(fun _ ->
                  if not !switched then begin
                    switched := true;
                    Result.get_ok (Masc.Mcp_server.set_workspace_config state scope.config)
                  end) ())
          in
          (match result with
           | Ok (Masc_http_client.Pool.Streamed _) -> ()
           | Ok (Masc_http_client.Pool.Buffered _) -> Alcotest.fail "fleet response was buffered"
           | Error detail -> Alcotest.failf "fleet stream failed: %s" detail);
          Alcotest.(check bool) "the first workspace was attested" true !attested;
          Alcotest.(check bool) "the first scope delivered its snapshot" true !switched;
          let new_scope = Masc.Mcp_server.workspace_scope state in
          let new_hub = hub_for new_scope in
          Alcotest.(check bool) "the replacement has no old snapshot" true
            (Option.is_none (Masc.Fleet_stream_hub.current new_hub));
          Masc.Fleet_stream_hub.note_degraded new_hub ~since:20. Masc.Fleet_stream.Scan_timed_out;
          let reader = Masc_tui_fleet_stream.create () in
          let exception Snapshot_received in
          (match Http.observe_fleet_stream ~clock ~expected_workspace:
               { identity with
                 sid_base_path = Masc.Tui_decode.Canonical_path.of_path (Unix.realpath workspace)
               ; sid_masc_root = Masc.Tui_decode.Canonical_path.of_path
                   (Unix.realpath (Filename.concat workspace ".masc")) }
               ~host:"127.0.0.1" ~port ~on_chunk:(fun chunk ->
                 ignore (Masc_tui_fleet_stream.feed reader chunk : Masc_tui_fleet_stream.step);
                 match Masc_tui_fleet_stream.view reader with
                 | Masc_tui_fleet_stream.Unavailable _ -> raise Snapshot_received
                 | _ -> ()) with
           | exception Snapshot_received -> ()
           | _ -> Alcotest.fail "the replacement stream supplied no snapshot");
          Alcotest.(check bool) "the replacement received only its own state" true
            (match Masc_tui_fleet_stream.view reader with
             | Masc_tui_fleet_stream.Unavailable { degradation; _ } ->
                 degradation.reason = Masc.Fleet_stream.Scan_timed_out
             | _ -> false))))
;;

(* The waiting-inventory client opens its own Observer without initialize or
   a shared MCP cookie. Keep that entrypoint distinct from initialized MCP. *)
let with_standalone_observer_server env body =
  let module Transport = Server_mcp_transport_http in
  let workspace = Masc_test_deps.setup_test_workspace () in
  Fun.protect
    ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> Eio.Switch.run (fun sw ->
      let clock = Eio.Stdenv.clock env in
      let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
      Auth.save_auth_config workspace
        { Masc_domain.default_auth_config with enabled = true; require_token = true };
      Masc_test_deps.ensure_rng_initialized ();
      let token =
        match Auth.create_token workspace ~agent_name:"waiting-observer" ~role:Masc_domain.Admin with
        | Ok (token, _) -> token
        | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error)
      in
      let authority =
        match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
        | Ok authority -> authority
        | Error `Malformed -> Alcotest.fail "fixture authority"
      in
      let verify check ~base_path request =
        check ~base_path request
        |> Result.map (fun _ -> ())
        |> Result.map_error Server_mcp_transport_http_types.auth_failure_of_masc_error
      in
      let runtime : Transport.runtime =
        { base_path = workspace; sw; clock
        ; tool_allowed_in_profile = (fun _ _ -> true)
        ; handle_request =
            (fun ?profile:_ ?mcp_session_id:_ ?otel_mcp_protocol_version:_
                 ?otel_transport_context:_ ?auth_token:_ ?internal_keeper_runtime:_ _ -> `Null)
        ; clear_resource_subscriptions_for_session = (fun _ -> ())
        }
      in
      let deps : Transport.deps =
        { get_origin = (fun _ -> ""); cors_headers = (fun _ -> [])
        ; auth_token_from_request = Server_auth.auth_token_from_request
        ; is_ready = (fun () -> true); get_runtime_result = (fun () -> Ok runtime)
        ; get_base_path = (fun () -> workspace); get_server_state = (fun () -> Some state)
        ; verify_mcp_auth = verify Server_auth.verify_mcp_auth
        ; verify_mcp_observer_stream_auth = verify Server_auth.verify_mcp_observer_stream_auth
        ; verify_operator_mcp_auth = verify Server_auth.verify_operator_mcp_auth
        ; verify_seat_mcp_auth = verify Server_auth.verify_seat_mcp_auth
        }
      in
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        let reqd = Masc.Http_reqd.of_httpun reqd in
        let uri = Uri.of_string request.target in
        Server_request_authority.with_current authority (fun () ->
          if String.equal (Uri.path uri) "/mcp" then
            let sse_kind = match Uri.get_query_param uri "sse_kind" with
              | Some "observer" -> Masc.Sse.Observer
              | Some _ | None -> Masc.Sse.Agent_stream
            in
            Transport.handle_get_mcp ~deps ~sse_kind request reqd
          else
            Server_dashboard_http_keeper_api.handle_keeper_get_subroutes state request request reqd)
      in
      with_server env ~handler (fun ~port -> body ~workspace ~state ~token ~sw ~clock ~port)))
;;

let test_standalone_observer_delivers_waiting_inventory_changes env =
  let module Transport = Server_mcp_transport_http in
  with_standalone_observer_server env (fun ~workspace ~state ~token ~sw ~clock ~port ->
    let profiles_before = Server_mcp_transport_http_session.For_testing.profile_count () in
    let clients_before = (Atomic.get Masc.Sse.clients).entries in
    let response, publish_response = Eio.Promise.create () in
    let received, publish_received = Eio.Promise.create () in
    let ended, publish_ended = Eio.Promise.create () in
    let decoder = Sse_wire.create_decoder () in
    let invalidation = `Assoc
        [ "type", `String "keeper_waiting_inventory_changed"
        ; "keeper_name", `String "alpha"; "queue_kind", `String "event_queue" ] in
    let invalidation_json = Yojson.Safe.to_string invalidation in
    let url = Printf.sprintf "http://127.0.0.1:%d/mcp?sse_kind=observer" port in
    let headers = ["Accept", "text/event-stream"; "Authorization", "Bearer " ^ token] in
    Eio.Fiber.fork ~sw (fun () ->
      let result = Masc_http_client.get_stream ~clock ~idle_timeout_sec:3. ~url ~headers
          ~on_response:(fun ~status ~headers ->
            ignore (Eio.Promise.try_resolve publish_response (status, headers)))
          ~on_chunk:(fun chunk ->
            Sse_wire.feed decoder chunk |> List.iter (fun (frame : Sse_wire.frame) ->
              if String.equal frame.data invalidation_json then
                ignore (Eio.Promise.try_resolve publish_received ()))) () in
      Eio.Promise.resolve publish_ended result);
    let await promise = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await promise) in
    let status, response_headers = await response in
    Alcotest.(check int) "fresh observer opens without initialize or a session cookie" 200 status;
    (* The standalone connection id is internal; find this fixture's new
       registration in the registry for the existing lifecycle assertions. *)
    let authority = Masc.Sse.runtime_authority_exn ~base_path:workspace in
    let session_ids = (Atomic.get Masc.Sse.clients).entries |> Masc.Sse.SMap.bindings
      |> List.filter_map (fun (id, (client : Masc.Sse.client)) ->
        if not (Masc.Sse.SMap.mem id clients_before)
           && Masc.Sse.equal_runtime_authority authority client.runtime_authority
        then Some id else None) in
    let session_id = match session_ids with
      | [id] -> id | _ -> Alcotest.fail "fresh observer has no unique registration" in
    Fun.protect
      ~finally:(fun () -> Eio.Cancel.protect (fun () -> Transport.stop_sse_session session_id))
      (fun () ->
        let instance = match Sse_wire.decode_observer_response response_headers with
          | Ok (Some { instance_id; replay = Sse_wire.Fresh }) -> instance_id
          | Ok (Some { replay = (Sse_wire.Resumed | Resumed_after_gap _ | Reset _); _ })
          | Ok None | Error _ -> Alcotest.fail "fresh observer has no scoped handshake" in
        Alcotest.(check bool) "observer does not initialize an MCP session" false
          (Transport.is_known_session session_id);
        Alcotest.(check bool) "observer creates no MCP backing session" true
          (Option.is_none (Masc.Session.McpSessionStore.peek session_id));
        Alcotest.(check int) "observer creates no orphan MCP profile" profiles_before
          (Server_mcp_transport_http_session.For_testing.profile_count ());
        let scope = Masc.Mcp_server.workspace_scope state in
        let observer_scope = Masc.Sse.observer_scope
            ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path:workspace)
            ~instance_id:instance in
        Alcotest.(check string) "observer carries the admitted workspace instance"
          (Server_observer_scope.instance_id scope) instance;
        Masc.Sse.broadcast_to (Masc.Sse.Scoped_runtime_observers observer_scope) invalidation;
        await received;
        let inventory_url = Printf.sprintf "http://127.0.0.1:%d/api/v1/keepers/alpha/waiting-inventory" port in
        let inventory = match Masc_http_client.get_response_sync ~clock ~timeout_sec:3.
            ~url:inventory_url ~headers:["Authorization", "Bearer " ^ token;
              Sse_wire.instance_header, instance] () with
          | Ok value -> value | Error detail -> Alcotest.fail detail in
        Alcotest.(check int) "the invalidated inventory is readable" 200 inventory.status;
        Alcotest.(check (option string)) "inventory attests the same observer instance"
          (Some instance)
          (List.find_map (fun (key, value) ->
             if String.equal (String.lowercase_ascii key) Sse_wire.instance_header
             then Some value else None) inventory.headers);
        let json = Yojson.Safe.from_string inventory.body in
        Alcotest.(check string) "the response is the authoritative inventory"
          "server_keeper_waiting_inventory" Yojson.Safe.Util.(json |> member "source" |> to_string);
        Transport.stop_sse_session session_id;
        (match await ended with
         | Ok (Masc_http_client.Pool.Streamed _) -> ()
         | Ok (Masc_http_client.Pool.Buffered _) -> Alcotest.fail "observer was buffered"
         | Error detail -> Alcotest.failf "observer close failed: %s" detail);
        Alcotest.(check bool) "disconnect removes the standalone observer" false
          (Masc.Sse.exists session_id)))
;;

(* Reproduce a browser's cookie jar and a client that returns the MCP header.
   Each request uses exactly the identifier the first response supplied. *)
let test_standalone_observer_reconnects_with_response_identifiers env =
  let module Transport = Server_mcp_transport_http in
  with_standalone_observer_server env (fun ~workspace ~state:_ ~token ~sw ~clock ~port ->
    let before = (Atomic.get Masc.Sse.clients).entries in
    let authority = Masc.Sse.runtime_authority_exn ~base_path:workspace in
    let pending = ref [] in
    let await promise = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await promise) in
    let url = Printf.sprintf "http://127.0.0.1:%d/mcp?sse_kind=observer" port in
    (* This legacy revision emits session identifiers before the fix. *)
    let legacy_version = "2025-03-26" in
    let base_headers = ["Accept", "text/event-stream"; "Authorization", "Bearer " ^ token;
                        "Mcp-Protocol-Version", legacy_version] in
    let open_stream extra_headers =
      let response, publish_response = Eio.Promise.create () in
      let ended, publish_ended = Eio.Promise.create () in
      pending := ended :: !pending;
      Eio.Fiber.fork ~sw (fun () ->
        let result = Masc_http_client.get_stream ~clock ~idle_timeout_sec:3. ~url
            ~headers:(extra_headers @ base_headers)
            ~on_response:(fun ~status ~headers ->
              ignore (Eio.Promise.try_resolve publish_response (status, headers)))
            ~on_chunk:ignore () in
        Eio.Promise.resolve publish_ended result);
      await response
    in
    Fun.protect
      ~finally:(fun () -> Eio.Cancel.protect (fun () ->
        let entries = (Atomic.get Masc.Sse.clients).entries in
        Masc.Sse.SMap.iter (fun id (client : Masc.Sse.client) ->
          if not (Masc.Sse.SMap.mem id before)
             && Masc.Sse.equal_runtime_authority authority client.runtime_authority
          then Transport.stop_sse_session id) entries;
        List.iter (fun ended -> ignore (await ended)) !pending))
      (fun () ->
        let status, headers = open_stream [] in
        Alcotest.(check int) "initial standalone observer opens" 200 status;
        let header name = List.find_map (fun (key, value) ->
          if String.equal (String.lowercase_ascii key) name then Some value else None) headers in
        Alcotest.(check (option string)) "observer uses the legacy protocol"
          (Some legacy_version) (header "mcp-protocol-version");
        let cookie = Option.map (fun value ->
          match String.split_on_char ';' value with first :: _ -> first | [] -> value)
          (header "set-cookie") in
        let session_id = header "mcp-session-id" in
        let returned name = function Some value -> [name, value] | None -> [] in
        let cookie_status, _ = open_stream (returned "Cookie" cookie) in
        Alcotest.(check int) "reconnect with the response cookie" 200 cookie_status;
        let header_status, _ = open_stream (returned "Mcp-Session-Id" session_id) in
        Alcotest.(check int) "reconnect with the response session header" 200 header_status;
        Alcotest.(check (option string)) "standalone response has no session cookie" None cookie;
        Alcotest.(check (option string)) "standalone response has no MCP session id" None session_id))
;;

let test_standalone_observer_window_survives_connection_cleanup env =
  let module Transport = Server_mcp_transport_http in
  Masc_test_deps.with_process_env "MASC_SSE_RECONNECT_MIN_INTERVAL_S" (Some "3600") @@ fun () ->
  Masc_test_deps.with_process_env "MASC_SSE_CONNECT_WINDOW_S" (Some "60") @@ fun () ->
  Masc_test_deps.with_process_env "MASC_SSE_CONNECT_MAX_IN_WINDOW" (Some "2") @@ fun () ->
  with_standalone_observer_server env (fun ~workspace ~state:_ ~token ~sw ~clock ~port ->
    let before = (Atomic.get Masc.Sse.clients).entries in
    let authority = Masc.Sse.runtime_authority_exn ~base_path:workspace in
    let initial_count = Masc.Sse.client_count () in
    let pending = ref [] in
    let await promise = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await promise) in
    let url = Printf.sprintf "http://127.0.0.1:%d/mcp?sse_kind=observer" port in
    let open_stream credential =
      let response, publish_response = Eio.Promise.create () in
      let ended, publish_ended = Eio.Promise.create () in
      pending := ended :: !pending;
      Eio.Fiber.fork ~sw (fun () ->
        let result = Masc_http_client.get_stream ~clock ~idle_timeout_sec:3. ~url
            ~headers:["Accept", "text/event-stream";
                      "Authorization", "Bearer " ^ credential;
                      "Mcp-Protocol-Version", "2025-03-26"]
            ~on_response:(fun ~status ~headers ->
              ignore (Eio.Promise.try_resolve publish_response (status, headers)))
            ~on_chunk:ignore () in
        Eio.Promise.resolve publish_ended result);
      await response
    in
    let close_new_clients () =
      Masc.Sse.SMap.iter (fun id (client : Masc.Sse.client) ->
        if not (Masc.Sse.SMap.mem id before)
           && Masc.Sse.equal_runtime_authority authority client.runtime_authority
        then Transport.stop_sse_session id) (Atomic.get Masc.Sse.clients).entries;
      List.iter (fun ended -> ignore (await ended)) !pending
    in
    Fun.protect
      ~finally:(fun () -> Eio.Cancel.protect close_new_clients)
      (fun () ->
        let first, _ = open_stream token in
        let concurrent, _ = open_stream token in
        Alcotest.(check int) "first subscription" 200 first;
        Alcotest.(check int) "another tab is not a same-session cooldown" 200 concurrent;
        Alcotest.(check int) "both subscriptions remain registered"
          (initial_count + 2) (Masc.Sse.client_count ());
        close_new_clients ();
        Alcotest.(check int) "fixture connections retired" initial_count (Masc.Sse.client_count ());
        let limited, headers = open_stream token in
        Alcotest.(check int) "new internal ids do not reset the actor window" 429 limited;
        let header name = List.find_map (fun (key, value) ->
          if String.equal (String.lowercase_ascii key) name then Some value else None) headers in
        Alcotest.(check (option string)) "429 has no reusable MCP session id" None (header "mcp-session-id");
        Alcotest.(check (option string)) "429 has no MCP cookie" None (header "set-cookie");
        Alcotest.(check (option string)) "429 retains the negotiated protocol"
          (Some "2025-03-26") (header "mcp-protocol-version");
        Alcotest.(check bool) "429 supplies a positive retry delay" true
          (Option.fold ~none:false ~some:(fun value ->
            Option.fold ~none:false ~some:(fun seconds -> seconds > 0) (int_of_string_opt value))
             (header "retry-after"));
        let repeated, _ = open_stream token in
        Alcotest.(check int) "a further sessionless attempt stays refused" 429 repeated;
        let forged, _ = open_stream "forged" in
        Alcotest.(check int) "authentication still precedes rate admission" 401 forged;
        Alcotest.(check int) "refused attempts publish no client or eviction"
          initial_count (Masc.Sse.client_count ());
        let other_token = match Auth.create_token workspace ~agent_name:"independent-observer"
            ~role:Masc_domain.Admin with
          | Ok (token, _) -> token
          | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error)
        in
        let independent, _ = open_stream other_token in
        Alcotest.(check int) "another authenticated agent has its own window" 200 independent;
        Masc_test_deps.with_process_env "MASC_SSE_CONNECT_MAX_IN_WINDOW" (Some "-1") (fun () ->
          let disabled, _ = open_stream token in
          Alcotest.(check int) "disabling the window does not enable a shared cooldown" 200 disabled)))
;;

let with_standalone_guard_window env body =
  let module Registry = Server_mcp_transport_http_conn in
  Masc_test_deps.with_process_env "MASC_SSE_RECONNECT_MIN_INTERVAL_S" (Some "3600") @@ fun () ->
  Masc_test_deps.with_process_env "MASC_SSE_CONNECT_WINDOW_S" (Some "60") @@ fun () ->
  Masc_test_deps.with_process_env "MASC_SSE_CONNECT_MAX_IN_WINDOW" (Some "2") @@ fun () ->
  with_standalone_observer_server env (fun ~workspace ~state ~token ~sw:_ ~clock:_ ~port:_ ->
    let credential = match Auth.find_credential_by_token workspace ~token with
      | Ok credential -> credential
      | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error)
    in
    let observer_instance_id = Server_observer_scope.instance_id (Masc.Mcp_server.workspace_scope state) in
    let admit now = Registry.For_testing.check_standalone_observer_connect_guard
        ~now ~observer_instance_id ~credential in
    let reap now = ignore (Registry.For_testing.reap_stale_guards ~now) in
    Fun.protect ~finally:(fun () -> ignore (Registry.reap_stale_guards ()))
      (fun () -> body ~admit ~reap))
;;

let expect_guard_admission label = function
  | Ok () -> ()
  | Error (reason, delay) -> Alcotest.failf "%s: %s (%.3fs)" label
      (Sse_reject_reason.to_label reason) delay
;;

let expect_guard_window_refusal label = function
  | Ok () -> Alcotest.fail (label ^ ": unexpectedly admitted")
  | Error (reason, delay) ->
      Alcotest.(check string) (label ^ ": reason") "window_limit" (Sse_reject_reason.to_label reason);
      Alcotest.(check bool) (label ^ ": positive retry delay") true (delay > 0.0)
;;

let test_standalone_guard_retains_later_time_after_reversed_completion env =
  with_standalone_guard_window env (fun ~admit ~reap ->
    (* Real admission and maintenance state, with captured timestamps completing
       in reverse order. This does not claim a multi-domain scheduler trace. *)
    expect_guard_admission "later request commits first" (admit 59.0);
    expect_guard_admission "earlier captured request completes later" (admit 0.0);
    reap 61.0;
    expect_guard_window_refusal "reaper retains the live window" (admit 61.0);
    reap 119.0;
    expect_guard_admission "the recorded window eventually expires" (admit 119.0))
;;

let test_standalone_guard_expires_each_boundary_entry_once env =
  with_standalone_guard_window env (fun ~admit ~reap ->
    expect_guard_admission "first request" (admit 0.0);
    expect_guard_admission "second request" (admit 59.0);
    expect_guard_admission "exactly one slot expires at the boundary" (admit 60.0);
    expect_guard_window_refusal "the expired oldest entry cannot keep granting slots" (admit 60.0);
    reap 61.0;
    expect_guard_window_refusal "maintenance retains both current entries" (admit 61.0);
    expect_guard_admission "the next old entry expires" (admit 119.0);
    expect_guard_window_refusal "its slot is consumed once" (admit 119.0))
;;

let test_standalone_observer_keeps_auth_and_supplied_session_checks env =
  with_standalone_observer_server env (fun ~workspace:_ ~state:_ ~token ~sw:_ ~clock ~port ->
    let client_count = Masc.Sse.client_count () in
    let supplied_id = "unknown-waiting-observer-" ^ string_of_int (Random.bits ()) in
    let bearer = ["Authorization", "Bearer " ^ token] in
    let cases =
      [ "missing credential", "/mcp?sse_kind=observer", [], 401
      ; "forged credential", "/mcp?sse_kind=observer", ["Authorization", "Bearer forged"], 401
      ; "supplied unknown observer id", "/mcp?sse_kind=observer",
          ("Mcp-Session-Id", supplied_id) :: bearer, 404
      ; "supplied unknown observer cookie", "/mcp?sse_kind=observer",
          ("Cookie", "mcp-session-id=" ^ supplied_id) :: bearer, 404
      ; "agent stream without initialize", "/mcp", bearer, 404
      ] in
    List.iter (fun (label, target, credentials, expected_status) ->
      let url = Printf.sprintf "http://127.0.0.1:%d%s" port target in
      let response = match Masc_http_client.get_response_sync ~clock ~timeout_sec:3.
          ~url ~headers:(("Accept", "text/event-stream") :: credentials) () with
        | Ok value -> value | Error detail -> Alcotest.failf "%s: %s" label detail in
      Alcotest.(check int) label expected_status response.status;
      Alcotest.(check int) (label ^ ": no observer registered") client_count (Masc.Sse.client_count ())) cases;
    Alcotest.(check bool) "provided unknown id was not minted" true
      (Option.is_none (Masc.Session.McpSessionStore.peek supplied_id));
    Server_mcp_transport_http.forget_mcp_session supplied_id)
;;

(* Exercise the real MCP GET handler over H1. Authentication is supplied by
   this fixture; the assertion is that ambiguous cursors stop before SSE
   registration. *)
let test_mcp_rejects_duplicate_cursors_before_registration env =
  let module Transport = Server_mcp_transport_http in
  let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
    | Ok authority -> authority | Error `Malformed -> Alcotest.fail "fixture authority" in
  let admit ~base_path:_ _request = Ok () in
  let deps : Transport.deps =
    { get_origin = (fun _ -> "")
    ; cors_headers = (fun _ -> [])
    ; auth_token_from_request = (fun _ -> None)
    ; is_ready = (fun () -> true)
    ; get_runtime_result = (fun () -> Error "unused")
    ; get_base_path = (fun () -> "/tmp/observer-test")
    ; get_server_state = (fun () -> None)
    ; verify_mcp_auth = admit
    ; verify_mcp_observer_stream_auth = admit
    ; verify_operator_mcp_auth = admit
    ; verify_seat_mcp_auth = admit
    } in
  let handler reqd =
    let request = Httpun.Reqd.request reqd in
    let reqd = Masc.Http_reqd.of_httpun reqd in
    Server_request_authority.with_current authority (fun () ->
      Transport.handle_get_mcp ~deps ~sse_kind:Masc.Sse.Observer request reqd) in
  List.iter (fun cursors ->
    with_server env ~handler (fun ~port ->
      let before = Masc.Sse.client_count () in
      let url = Printf.sprintf "http://127.0.0.1:%d/mcp?sse_kind=observer" port in
      let headers = [ "Accept", "text/event-stream"; "Mcp-Session-Id", "observer-duplicate-test"
                    ; "x-masc-sse-instance-id", "process-a" ] @ cursors in
      match Masc_http_client.get_response_sync ~clock:(Eio.Stdenv.clock env) ~timeout_sec:3.
              ~url ~headers () with
      | Error detail -> Alcotest.failf "MCP request failed: %s" detail
      | Ok response ->
        Alcotest.(check int) "ambiguous request is rejected" 400 response.status;
        Alcotest.(check int) "no observer was registered" before (Masc.Sse.client_count ())))
    [ [ "Last-Event-ID", "20"; "last-event-id", "50" ]
    ; [ "last-event-id", "50"; "Last-Event-ID", "20" ]
    ; [ "last-event-id", "20"; "Last-Event-ID", "20" ] ]
;;

let test_mcp_rejects_unknown_machine_and_non_observer_machine env =
  let module Transport = Server_mcp_transport_http in
  let workspace = Masc_test_deps.setup_test_workspace () in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace) (fun () ->
    let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
    let auth = Masc_test_deps.make_sse_auth workspace "machine-observer" in
    let token = Option.get auth.Masc.Sse.token in
    ignore (Masc.Session.McpSessionStore.get_or_create ~id:"observer-machine-test" ());
    let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
      | Ok authority -> authority | Error `Malformed -> Alcotest.fail "fixture authority" in
    let admit ~base_path:_ _request = Ok () in
    let deps : Transport.deps =
      { get_origin = (fun _ -> "")
      ; cors_headers = (fun _ -> [])
      ; auth_token_from_request = (fun _ -> None)
      ; is_ready = (fun () -> true)
      ; get_runtime_result = (fun () -> Error "runtime unavailable")
      ; get_base_path = (fun () -> workspace)
      ; get_server_state = (fun () -> Some state)
      ; verify_mcp_auth = admit
      ; verify_mcp_observer_stream_auth = admit
      ; verify_operator_mcp_auth = admit
      ; verify_seat_mcp_auth = admit
      } in
    List.iter (fun (target, sse_kind, expected_status) ->
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        let reqd = Masc.Http_reqd.of_httpun reqd in
        Server_request_authority.with_current authority (fun () ->
          Transport.handle_get_mcp ~deps ~sse_kind request reqd) in
      with_server env ~handler (fun ~port ->
        let before = Masc.Sse.client_count () in
        let url = Printf.sprintf "http://127.0.0.1:%d%s" port target in
        match Masc_http_client.get_response_sync ~clock:(Eio.Stdenv.clock env) ~timeout_sec:3.
                ~url ~headers:[ "Accept", "text/event-stream"; "Mcp-Session-Id", "observer-machine-test"
                              ; "Authorization", "Bearer " ^ token ] () with
        | Error detail -> Alcotest.failf "MCP request failed: %s" detail
        | Ok response ->
          if response.status <> expected_status then
            Alcotest.failf "%s: expected %d, got %d: %s" target expected_status response.status response.body;
          Alcotest.(check int) "no observer was registered" before (Masc.Sse.client_count ())))
      [ "/mcp?sse_kind=observer&machine=other", Masc.Sse.Observer, 400
      ; "/mcp?sse_kind=agent&machine=msx", Masc.Sse.Agent_stream, 400
      ; "/mcp?sse_kind=observer&machine=msx", Masc.Sse.Observer, 503 ])
;;

let test_mcp_observer_refuses_foreign_and_retired_workspaces env =
  let module Transport = Server_mcp_transport_http in
  let workspace = Masc_test_deps.setup_test_workspace () in
  Fun.protect ~finally:(fun () -> Masc_test_deps.cleanup_test_workspace workspace) (fun () ->
    let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
    let scope = Masc.Mcp_server.workspace_scope state in
    let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
      | Ok authority -> authority | Error `Malformed -> Alcotest.fail "fixture authority" in
    let mode = ref `Admit in
    let readiness = ref (fun () -> true) in
    let runtime_result = ref (fun () -> Error "unused") in
    let auth = Masc_test_deps.make_sse_auth workspace "ready-change" in
    let token = Option.get auth.Masc.Sse.token in
    let verify ~base_path:_ _request =
      match !mode with
      | `Admit -> Ok ()
      | `Deny -> Error { Transport.message = "fixture denied"; auth_error_code = None }
      | `Replace ->
        Result.get_ok (Masc.Mcp_server.set_workspace_config state scope.config);
        Ok ()
    in
    let deps : Transport.deps =
      { get_origin = (fun _ -> "")
      ; cors_headers = (fun _ -> [])
      ; auth_token_from_request = (fun _ -> None)
      ; is_ready = (fun () -> !readiness ())
      ; get_runtime_result = (fun () -> !runtime_result ())
      ; get_base_path = (fun () -> workspace)
      ; get_server_state = (fun () -> Some state)
      ; verify_mcp_auth = verify
      ; verify_mcp_observer_stream_auth = verify
      ; verify_operator_mcp_auth = verify
      ; verify_seat_mcp_auth = verify
      } in
    let handler reqd =
      let request = Httpun.Reqd.request reqd in
      let reqd = Masc.Http_reqd.of_httpun reqd in
      Server_request_authority.with_current authority (fun () ->
        Transport.handle_get_mcp ~deps ~sse_kind:Masc.Sse.Observer request reqd)
    in
    with_server env ~handler (fun ~port ->
      let before = Masc.Sse.client_count () in
      let query fields =
        Uri.add_query_params' (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/mcp" port))
          (("sse_kind", "observer") :: fields) |> Uri.to_string
      in
      let check label fields expected_status =
        let url = query fields in
        match Masc_http_client.get_response_sync ~clock:(Eio.Stdenv.clock env) ~timeout_sec:3.
            ~url ~headers:["Accept", "text/event-stream"; "Mcp-Session-Id", label;
                           "Authorization", "Bearer " ^ token] () with
        | Error detail -> Alcotest.failf "%s: %s" label detail
        | Ok response ->
          Alcotest.(check int) label expected_status response.status;
          Alcotest.(check int) (label ^ ": no observer registered") before (Masc.Sse.client_count ())
      in
      let base = Unix.realpath workspace in
      let root = Unix.realpath (Filename.concat workspace ".masc") in
      check "foreign" ["expected_base_path", "/foreign"; "expected_masc_root", root] 409;
      check "partial" ["expected_base_path", base] 400;
      check "duplicate" ["expected_base_path", base; "expected_base_path", base;
                         "expected_masc_root", root] 400;
      mode := `Deny;
      check "authentication precedes workspace refusal"
        ["expected_base_path", "/foreign"; "expected_masc_root", root] 401;
      mode := `Replace;
      check "same-path scope replacement during authentication"
        ["expected_base_path", base; "expected_masc_root", root] 409;
      mode := `Admit;
      let checks = ref 0 in
      readiness := (fun () -> incr checks; !checks = 1);
      ignore (Masc.Session.McpSessionStore.get_or_create ~id:"readiness-lost" ());
      check "readiness-lost" ["expected_base_path", base; "expected_masc_root", root] 503;
      Alcotest.(check int) "readiness was rechecked after registration" 2 !checks;
      checks := 0;
      readiness := (fun () -> incr checks; !checks < 3);
      ignore (Masc.Session.McpSessionStore.get_or_create ~id:"readiness-lost-late" ());
      check "readiness-lost-late" ["expected_base_path", base; "expected_masc_root", root] 503;
      Alcotest.(check int) "readiness was rechecked before response" 3 !checks;
      readiness := (fun () -> true);
      runtime_result := (fun () ->
        Result.get_ok (Masc.Mcp_server.set_workspace_config state scope.config);
        Error "scope changed");
      ignore (Masc.Session.McpSessionStore.get_or_create ~id:"scope-lost-late" ());
      check "scope-lost-late" ["expected_base_path", base; "expected_masc_root", root] 409;
      runtime_result := (fun () -> Error "unused");
      ignore (Masc.Session.McpSessionStore.get_or_create ~id:"no-runtime" ());
      let url = query ["expected_base_path", base; "expected_masc_root", root] in
      let response = match Masc_http_client.get_response_sync ~clock:(Eio.Stdenv.clock env)
          ~timeout_sec:3. ~url ~headers:["Accept", "text/event-stream";
            "Mcp-Session-Id", "no-runtime"; "Authorization", "Bearer " ^ token] () with
        | Ok response -> response
        | Error detail -> Alcotest.failf "runtime unavailable: %s" detail in
      Alcotest.(check int) "unavailable runtime retains the existing stream status" 200 response.status;
      Alcotest.(check int) "unavailable runtime leaves no observer registered" before (Masc.Sse.client_count ());
      Alcotest.(check bool) "unavailable runtime carries no identity receipt" true
        (Sse_wire.decode_observer_identity response.headers = Ok None)))
;;

(* A retired scope's delayed close must not remove a successor that reused
   the same session. Both responses here are real loopback connections, and
   each has the supervisor that closes it, as every served stream does. *)
let test_retired_observer_close_keeps_successor env =
  let module Conn = Server_mcp_transport_http_conn in
  let session_id = "observer-owner-" ^ string_of_int (Random.bits ()) in
  let first, first_open = Eio.Promise.create () in
  let second, second_open = Eio.Promise.create () in
  let opened = ref 0 in
  let handler ~sw reqd =
    incr opened;
    let headers = Httpun.Headers.of_list
        ["content-type", "text/event-stream"; "connection", "close"] in
    let response =
      Server_sse_response.respond ~clock:(Eio.Stdenv.clock env)
        ~stalled_after_s:Server_mcp_transport_http_headers.sse_stalled_after_s
        (Masc.Http_reqd.of_httpun reqd)
        (Httpun.Response.create ~headers `OK)
    in
    let info = Conn.make_sse_conn ~session_id ~client_id:!opened ~response () in
    Conn.register_sse_conn ~session_id ~info;
    Conn.run_sse_pumps ~sw info ~drain:Eio.Fiber.await_cancel ~ping:Eio.Fiber.await_cancel;
    Alcotest.(check bool) "the opening frame was sent" true
      (match Conn.send_raw info ": open\n\n" with
       | Written -> true
       | Closed | Stalled -> false);
    if !opened = 1 then Eio.Promise.resolve first_open info
    else Eio.Promise.resolve second_open info
  in
  Fun.protect ~finally:(fun () -> Eio.Cancel.protect (fun () -> Conn.stop_sse_session session_id))
    (fun () -> Eio.Switch.run (fun sw ->
      with_server env ~handler:(handler ~sw) (fun ~port ->
        let ended, mark_ended = Eio.Stream.create 2, ref 0 in
        let connect () = Eio.Fiber.fork ~sw (fun () ->
          let url = Printf.sprintf "http://127.0.0.1:%d/mcp" port in
          ignore (Masc_http_client.get_stream ~clock:(Eio.Stdenv.clock env)
            ~idle_timeout_sec:3. ~url ~headers:[] ~on_response:(fun ~status:_ ~headers:_ -> ())
            ~on_chunk:(fun _ -> ()) ());
          incr mark_ended;
          Eio.Stream.add ended ()) in
        let await promise = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 3.
            (fun () -> Eio.Promise.await promise) in
        connect ();
        let old = await first in
        connect ();
        let successor = await second in
        Conn.stop_sse_conn_if_current old;
        Alcotest.(check bool) "successor stays registered" true (Conn.is_active_sse_session session_id);
        Alcotest.(check bool) "successor is still writable" true
          (match Conn.send_raw successor "data: {}\n\n" with
           | Written -> true
           | Closed | Stalled -> false);
        Conn.stop_sse_conn_if_current successor;
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 3. (fun () ->
          Eio.Stream.take ended; Eio.Stream.take ended);
        Alcotest.(check int) "both readers ended" 2 !mark_ended;
        Alcotest.(check bool) "successor was removed" false (Conn.is_active_sse_session session_id))))
;;

let test_play_observer_reconnect_keeps_replacement_presence env =
  let module Transport = Server_mcp_transport_http in
  let workspace = Masc_test_deps.setup_test_workspace () in
  let session_id = "play-observer-" ^ string_of_int (Random.bits ()) in
  let subscription = "play-observer-events-" ^ string_of_int (Random.bits ()) in
  let changes = ref 0 in
  Masc.Sse.subscribe_external
    ~runtime_authority:(Masc.Sse.runtime_authority_exn ~base_path:workspace)
    ~id:subscription
    ~callback:(fun (event : Masc.Sse.external_event) ->
      match event.ext_payload with
      | `Assoc fields ->
        (match Masc.Workspace_dataset_event.of_fields fields with
         | Ok (Masc.Workspace_dataset_event.Play_room _) -> incr changes
         | Ok _ | Error _ -> ())
      | _ -> ())
    ();
  Fun.protect
    ~finally:(fun () ->
      Masc.Sse.unsubscribe_external subscription;
      Eio.Cancel.protect (fun () -> Transport.stop_sse_session session_id);
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> Eio.Switch.run (fun sw ->
      let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
        | Ok authority -> authority | Error `Malformed -> Alcotest.fail "fixture authority" in
      let admit ~base_path:_ _request = Ok () in
      let runtime : Transport.runtime =
        { base_path = workspace
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; tool_allowed_in_profile = (fun _ _ -> true)
        ; handle_request =
            (fun ?profile:_ ?mcp_session_id:_ ?otel_mcp_protocol_version:_
                 ?otel_transport_context:_ ?auth_token:_ ?internal_keeper_runtime:_ _ -> `Null)
        ; clear_resource_subscriptions_for_session = (fun _ -> ())
        } in
      let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
      let scope = Masc.Mcp_server.workspace_scope state in
      let previous_authority = Masc.Sse.runtime_authority_exn ~base_path:scope.config.base_path in
      let instance_id = Masc.Build_identity.runtime_instance_id ^ "."
        ^ Masc.Mcp_server.Workspace_scope_epoch.to_string scope.epoch in
      ignore (Masc.Sse.observer_scope ~runtime_authority:previous_authority ~instance_id);
      let deps : Transport.deps =
        { get_origin = (fun _ -> "")
        ; cors_headers = (fun _ -> [])
        ; auth_token_from_request = (fun _ -> None)
        ; is_ready = (fun () -> true)
        ; get_runtime_result = (fun () -> Ok runtime)
        ; get_base_path = (fun () -> workspace)
        ; get_server_state = (fun () -> Some state)
        ; verify_mcp_auth = admit
        ; verify_mcp_observer_stream_auth = admit
        ; verify_operator_mcp_auth = admit
        ; verify_seat_mcp_auth = admit
        } in
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        let reqd = Masc.Http_reqd.of_httpun reqd in
        Server_request_authority.with_current authority (fun () ->
          Transport.handle_get_mcp ~deps ~sse_kind:Masc.Sse.Observer request reqd) in
      let auth = Masc_test_deps.make_sse_auth workspace "play-observer" in
      let token = Option.get auth.Masc.Sse.token in
      ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
      let member_names () =
        match Masc.Play_room.read ~base_path:workspace ~now:(Time_compat.now ()) ~before:None with
        | Ok snapshot -> List.map (fun (member : Masc.Play_room.member) -> member.name) snapshot.members
        | Error error -> Alcotest.fail (Masc.Play_room.error_message error)
      in
      let control_steps = ref 0 in
      Server_machine_spectator.For_testing.with_step
        (fun ~config:_ ~machine:_ -> incr control_steps; Ok ()) (fun () ->
        with_server env ~handler (fun ~port ->
          let open_observer () =
            let response, publish_response = Eio.Promise.create () in
            let ended, publish_ended = Eio.Promise.create () in
            let url =
              Uri.add_query_params'
                (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/mcp" port))
                [ "sse_kind", "observer"; "play_machine", "msx"; "play_client_id", "tab-1"
                ; "expected_base_path", Unix.realpath workspace
                ; "expected_masc_root", Unix.realpath (Filename.concat workspace ".masc") ]
              |> Uri.to_string
            in
            let headers =
              [ "Accept", "text/event-stream"; "Mcp-Session-Id", session_id
              ; "Authorization", "Bearer " ^ token; "x-masc-sse-instance-id", instance_id ]
            in
            Eio.Fiber.fork ~sw (fun () ->
              ignore (Masc_http_client.get_stream ~clock:(Eio.Stdenv.clock env)
                ~idle_timeout_sec:3. ~url ~headers
                ~on_response:(fun ~status ~headers:_ ->
                  ignore (Eio.Promise.try_resolve publish_response status))
                ~on_chunk:(fun _ -> ()) ());
              Eio.Promise.resolve publish_ended ());
            response, ended
          in
          let await promise = Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 3.
            (fun () -> Eio.Promise.await promise) in
          let first_response, first_ended = open_observer () in
          Alcotest.(check int) "the first Play observer opens" 200 (await first_response);
          Alcotest.(check (list string)) "connect owns membership" ["play-observer"] (member_names ());
          Alcotest.(check int) "the initial Join announces once" 1 !changes;
          let second_response, second_ended = open_observer () in
          Alcotest.(check int) "the replacement opens" 200 (await second_response);
          await first_ended;
          Alcotest.(check (list string)) "old disconnect keeps replacement presence"
            ["play-observer"] (member_names ());
          Alcotest.(check int) "handoff has no Leave/Join gap" 1 !changes;
          Alcotest.(check bool) "the replacement remains registered" true (Masc.Sse.exists session_id);
          Transport.stop_sse_session session_id;
          await second_ended;
          Alcotest.(check (list string)) "the exact final disconnect leaves" [] (member_names ());
          Alcotest.(check int) "the final Leave announces once" 2 !changes;
          Alcotest.(check int) "Play metadata never steps Control" 0 !control_steps))))
;;

module Play_fixture = Play_observer_fixture

let open_play ~sw ~clock ~port ~session_id ~token ~instance_id =
  Play_fixture.open_observer ~sw ~clock ~port ~session_id ~token ~instance_id ~play_client:"tab-1" ()

let http_play_action workspace operation =
  let action = Masc.Play_room.parse_action (`Assoc [
    "action", `String operation; "client_id", `String "tab-1"; "machine", `String "msx"
  ]) |> Result.get_ok in
  Server_play_room_events.perform_http ~base_path:workspace ~agent_name:"play-observer"
    ~role:Masc_domain.Player action |> Result.get_ok

let assert_http_join_available workspace =
  ignore (http_play_action workspace "join");
  Alcotest.(check (list string)) "HTTP Join remains available after cleanup"
    ["play-observer"] (Play_fixture.member_names workspace);
  ignore (http_play_action workspace "leave")

let test_stale_reconnect_cannot_replace_successor env =
  Play_fixture.with_fixture env (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
    let calls = ref 0 in
    let started, announce = Eio.Promise.create () in
    let release, resume = Eio.Promise.create () in
    Server_play_room_events.For_testing.with_permission
      (fun role permission ->
        incr calls;
        if !calls = 1 then begin
          Eio.Promise.resolve announce ();
          Eio.Promise.await release
        end;
        Masc_domain.has_permission role permission)
      (fun () ->
        let first = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
        Play_fixture.await clock started;
        let second = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
        Alcotest.(check int) "the successor publishes before the stale connect resumes"
          200 (Play_fixture.await clock second.response);
        Eio.Promise.resolve resume ();
        Play_fixture.await clock first.ended;
        Alcotest.(check bool) "the successor remains connected" false
          (Eio.Promise.is_resolved second.ended);
        Alcotest.(check bool) "the successor remains registered" true
          (Masc.Sse.exists session_id && Server_mcp_transport_http_conn.is_active_sse_session session_id);
        Masc.Sse.broadcast_to
          (Masc.Sse.Runtime_observers (Masc.Sse.runtime_authority_exn ~base_path:workspace))
          (`Assoc ["type", `String "successor-live"]);
        Play_fixture.await_condition clock (fun () ->
          List.exists (fun chunk -> Play_fixture.contains chunk "successor-live") !(second.chunks));
        Alcotest.(check (list string)) "the successor lease remains present"
          ["play-observer"] (Play_fixture.member_names workspace);
        Server_mcp_transport_http.stop_sse_session session_id;
        Play_fixture.await clock second.ended))

let test_disconnect_before_lease_install_cleans_up env =
  Play_fixture.with_fixture env (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
    let started, announce = Eio.Promise.create () in
    let release, resume = Eio.Promise.create () in
    let entered = ref false in
    Server_play_room_events.For_testing.with_permission
      (fun role permission ->
        if not !entered then begin
          entered := true;
          Eio.Promise.resolve announce ();
          Eio.Promise.await release
        end;
        Masc_domain.has_permission role permission)
      (fun () ->
        let first = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
        Play_fixture.await clock started;
        Masc.Sse.unregister session_id;
        Eio.Promise.resolve resume ();
        Play_fixture.await clock first.ended;
        Alcotest.(check (list string)) "a disconnected Observer cannot leave an orphaned lease"
          [] (Play_fixture.member_names workspace);
        assert_http_join_available workspace))

let test_aborted_replacement_cleans_predecessor_presence env =
  Play_fixture.with_fixture env (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
    let first = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
    Alcotest.(check int) "the established Observer opens" 200 (Play_fixture.await clock first.response);
    Alcotest.(check (list string)) "the established Observer owns presence"
      ["play-observer"] (Play_fixture.member_names workspace);
    Server_play_room_events.For_testing.with_perform
      (fun ~base_path ~who ~speaker ~now action ->
        match Masc.Play_room.presence action with
        | Some (Masc.Play_room.Join, _) -> Error (Masc.Play_room.Unavailable "injected connect failure")
        | Some (Masc.Play_room.Leave, _) | None ->
          Masc.Play_room.perform_with_change ~base_path ~who ~speaker ~now action)
      (fun () ->
        let second = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
        ignore (Play_fixture.await clock second.response);
        Play_fixture.await clock second.ended);
    Play_fixture.await clock first.ended;
    Alcotest.(check (list string)) "an aborted replacement removes the predecessor"
      [] (Play_fixture.member_names workspace);
    assert_http_join_available workspace)

let test_readiness_loss_cleans_predecessor_presence env =
  let ready = ref true in
  Play_fixture.with_fixture env ~ready:(fun () -> !ready)
    (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
      let first = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
      Alcotest.(check int) "the established Observer opens" 200 (Play_fixture.await clock first.response);
      Alcotest.(check (list string)) "the established Observer owns presence"
        ["play-observer"] (Play_fixture.member_names workspace);
      let previous_hook = Atomic.get Masc.Sse.register_commit_test_hook in
      Atomic.set Masc.Sse.register_commit_test_hook (Some (fun () -> ready := false));
      Fun.protect ~finally:(fun () -> Atomic.set Masc.Sse.register_commit_test_hook previous_hook)
        (fun () ->
          let second = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
          Alcotest.(check int) "readiness is lost after replacement" 503
            (Play_fixture.await clock second.response);
          Play_fixture.await clock first.ended);
      Alcotest.(check (list string)) "readiness loss removes the predecessor"
        [] (Play_fixture.member_names workspace);
      assert_http_join_available workspace)

let test_ping_scheduler_renews_play_presence env =
  Play_fixture.with_fixture env (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
    Server_mcp_transport_http.For_testing.with_ping_interval 0.05 (fun () ->
      let first = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
      Alcotest.(check int) "the Play observer opens" 200 (Play_fixture.await clock first.response);
      let before = match Masc.Play_room.read ~base_path:workspace ~now:(Time_compat.now ()) ~before:None with
        | Ok { members = [member]; _ } -> member
        | Ok _ | Error _ -> Alcotest.fail "the initial Play membership is missing"
      in
      Play_fixture.await_condition clock (fun () ->
        match Masc.Play_room.read ~base_path:workspace ~now:(Time_compat.now ()) ~before:None with
        | Ok { members = [member]; _ } -> member.seen_at > before.seen_at
        | Ok _ | Error _ -> false);
      Server_mcp_transport_http.stop_sse_session session_id;
      Play_fixture.await clock first.ended))

let test_transport_disconnect_finishes_leave_before_cancellation env =
  let exception Disconnect_fixture in
  Play_fixture.with_fixture env (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
    let first = open_play ~sw ~clock ~port ~session_id ~token ~instance_id in
    Alcotest.(check int) "the Play observer opens" 200 (Play_fixture.await clock first.response);
    let acquired, mark_acquired = Eio.Promise.create () in
    let release, release_lock = Eio.Promise.create () in
    let closing_info = ref None in
    let cancelled = ref false in
    let finished, mark_finished = Eio.Promise.create () in
    Server_mcp_transport_http.For_testing.with_disconnect_hook
      (fun info ->
        match info with
        | None -> Alcotest.fail "the published connection is missing"
        | Some info ->
          closing_info := Some info;
          Eio.Fiber.fork ~sw (fun () ->
            Eio.Promise.resolve mark_acquired ();
            Eio.Promise.await release);
          Eio.Promise.await acquired)
      (fun () ->
        Eio.Fiber.fork ~sw (fun () ->
          (try
            Eio.Cancel.sub (fun context ->
              Eio.Cancel.cancel context Disconnect_fixture;
              Masc.Sse.unregister session_id)
          with
          | Eio.Cancel.Cancelled Disconnect_fixture -> cancelled := true
          | Eio.Cancel.Cancelled _ -> ());
          Eio.Promise.resolve mark_finished ());
        Play_fixture.await clock acquired;
        (match !closing_info with
         | Some info -> Play_fixture.await_condition clock (fun () -> Atomic.get info.stop)
         | None -> Alcotest.fail "the disconnect fixture lost its connection");
        Eio.Promise.resolve release_lock ();
        Play_fixture.await clock finished);
    Alcotest.(check bool) "the transport preserves the original cancellation" true !cancelled;
    Alcotest.(check (list string)) "the transport still completes Play Leave"
      [] (Play_fixture.member_names workspace);
    assert_http_join_available workspace)

let test_generic_replacement_disconnects_predecessor_once env =
  Play_fixture.with_fixture env (fun ~workspace ~session_id ~token ~instance_id ~port ~sw ~clock ->
    let calls = ref 0 in
    Server_mcp_transport_http.For_testing.with_disconnect_hook
      (fun _ -> incr calls) (fun () ->
        let first = Play_fixture.open_observer ~sw ~clock ~port ~session_id ~token ~instance_id () in
        Alcotest.(check int) "the generic Observer opens" 200 (Play_fixture.await clock first.response);
        let second = Play_fixture.open_observer ~sw ~clock ~port ~session_id ~token ~instance_id () in
        Alcotest.(check int) "the generic replacement opens" 200 (Play_fixture.await clock second.response);
        Play_fixture.await clock first.ended;
        Alcotest.(check int) "the predecessor hook runs exactly once" 1 !calls;
        Alcotest.(check (list string)) "generic streams create no Play membership"
          [] (Play_fixture.member_names workspace);
        Server_mcp_transport_http.stop_sse_session session_id;
        Play_fixture.await clock second.ended;
        Alcotest.(check int) "the current disconnect runs its own hook once" 2 !calls;
        Alcotest.(check (list string)) "generic disconnect creates no Play membership"
          [] (Play_fixture.member_names workspace)))

let test_mcp_future_cursor_resets_before_live_delivery env =
  let module Transport = Server_mcp_transport_http in
  let workspace = Masc_test_deps.setup_test_workspace () in
  let session_id = "observer-future-test-" ^ string_of_int (Random.bits ()) in
  let successor_id = session_id ^ "-successor" in
  let auth = Masc_test_deps.make_sse_auth workspace "future-observer" in
  let token = Option.get auth.Masc.Sse.token in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:successor_id ());
  Fun.protect
    ~finally:(fun () ->
      Eio.Cancel.protect (fun () -> Transport.stop_sse_session session_id);
      Eio.Cancel.protect (fun () -> Transport.stop_sse_session successor_id);
      Masc_test_deps.cleanup_test_workspace workspace)
    (fun () -> Eio.Switch.run (fun sw ->
      let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
        | Ok authority -> authority | Error `Malformed -> Alcotest.fail "fixture authority" in
      let admit ~base_path:_ _request = Ok () in
      let runtime : Transport.runtime =
        { base_path = workspace
        ; sw
        ; clock = Eio.Stdenv.clock env
        ; tool_allowed_in_profile = (fun _ _ -> true)
        ; handle_request =
            (fun ?profile:_ ?mcp_session_id:_ ?otel_mcp_protocol_version:_
                 ?otel_transport_context:_ ?auth_token:_ ?internal_keeper_runtime:_ _ -> `Null)
        ; clear_resource_subscriptions_for_session = (fun _ -> ())
        } in
      let state = Masc.Mcp_server.For_testing.create_state ~base_path:workspace in
      let scope = Masc.Mcp_server.workspace_scope state in
      let previous_authority = Masc.Sse.runtime_authority_exn ~base_path:scope.config.base_path in
      let instance_id = Masc.Build_identity.runtime_instance_id ^ "."
        ^ Masc.Mcp_server.Workspace_scope_epoch.to_string scope.epoch in
      let previous_scope = Masc.Sse.observer_scope ~runtime_authority:previous_authority
        ~instance_id in
      let deps : Transport.deps =
        { get_origin = (fun _ -> "")
        ; cors_headers = (fun _ -> [])
        ; auth_token_from_request = (fun _ -> None)
        ; is_ready = (fun () -> true)
        ; get_runtime_result = (fun () -> Ok runtime)
        ; get_base_path = (fun () -> workspace)
        ; get_server_state = (fun () -> Some state)
        ; verify_mcp_auth = admit
        ; verify_mcp_observer_stream_auth = admit
        ; verify_operator_mcp_auth = admit
        ; verify_seat_mcp_auth = admit
        } in
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        let reqd = Masc.Http_reqd.of_httpun reqd in
        Server_request_authority.with_current authority (fun () ->
          Transport.handle_get_mcp ~deps ~sse_kind:Masc.Sse.Observer request reqd) in
      with_server env ~handler (fun ~port ->
        let response, publish_response = Eio.Promise.create () in
        let event, publish_event = Eio.Promise.create () in
        let ended, publish_ended = Eio.Promise.create () in
        let decoder = Sse_wire.create_decoder () in
        let url =
          Uri.add_query_params'
            (Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/mcp" port))
            [ "sse_kind", "observer"; "expected_base_path", Unix.realpath workspace
            ; "expected_masc_root", Unix.realpath (Filename.concat workspace ".masc") ]
          |> Uri.to_string
        in
        let headers =
          [ "Accept", "text/event-stream"
          ; "Mcp-Session-Id", session_id
          ; "Authorization", "Bearer " ^ token
          ; "x-masc-sse-instance-id", instance_id
          ; "Last-Event-ID", string_of_int max_int
          ] in
        Eio.Fiber.fork ~sw (fun () ->
          let result = Masc_http_client.get_stream ~clock:(Eio.Stdenv.clock env)
            ~idle_timeout_sec:3. ~url ~headers
            ~on_response:(fun ~status ~headers ->
              ignore (Eio.Promise.try_resolve publish_response (status, headers)))
            ~on_chunk:(fun chunk ->
              Sse_wire.feed decoder chunk |> List.iter (fun (frame : Sse_wire.frame) ->
                Option.iter (fun id -> ignore (Eio.Promise.try_resolve publish_event id)) frame.id)) () in
          Eio.Promise.resolve publish_ended result);
        let clock = Eio.Stdenv.clock env in
        let status, headers = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await response) in
        Alcotest.(check int) "MCP stream opens" 200 status;
        Alcotest.(check (option string)) "observer deadline follows server keepalives"
          (Some (string_of_int Server_mcp_transport_http_headers.observer_idle_timeout_ms))
          (List.find_map (fun (name, value) ->
             if String.equal (String.lowercase_ascii name)
                  Server_mcp_transport_http_headers.observer_idle_timeout_header
             then Some value else None) headers);
        Alcotest.(check bool) "the admitted observer carries the workspace receipt" true
          (List.exists (fun (name, value) ->
             String.equal (String.lowercase_ascii name) receipt_name && String.equal value (snd receipt)) headers);
        Alcotest.(check bool) "the ready scoped response attests its actual build" true
          (Sse_wire.decode_observer_identity headers =
           Ok (Some {version=(Masc.Build_identity.current ()).release_version;
                     binary_commit=Masc.Build_identity.embedded_commit}));
        let handshake = Sse_wire.decode_observer_response headers in
        let expected : Sse_wire.observer_handshake =
          { instance_id
          ; replay = Sse_wire.Reset Sse_wire.Cursor_ahead } in
        Alcotest.(check bool) "same-instance future cursor is reset" true
          (handshake = Ok (Some expected));
        Masc.Sse.broadcast_to Masc.Sse.Observers (`Assoc [ "type", `String "future-reset-live" ]);
        let id = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await event) in
        Alcotest.(check bool) "a lower live event is delivered" true
          (match int_of_string_opt id with Some id -> id < max_int | None -> false);
        Masc.Sse.broadcast_to Masc.Sse.Observers (`Assoc [ "type", `String "previous-scope-tail" ]);
        Result.get_ok (Masc.Mcp_server.set_workspace_config state scope.config);
        (match Eio.Time.with_timeout_exn clock 2. (fun () -> Eio.Promise.await ended) with
         | Ok (Masc_http_client.Pool.Streamed _) -> ()
         | Ok (Masc_http_client.Pool.Buffered _) -> Alcotest.fail "observer response was buffered"
         | Error detail -> Alcotest.failf "observer did not close cleanly: %s" detail);
        Alcotest.(check bool) "the old observer is unregistered" false (Masc.Sse.exists session_id);
        let next_response, publish_next_response = Eio.Promise.create () in
        let next_live, publish_next_live = Eio.Promise.create () in
        let next_decoder = Sse_wire.create_decoder () in
        let next_payloads = ref [] in
        let next_headers =
          [ "Accept", "text/event-stream"; "Mcp-Session-Id", successor_id
          ; "Authorization", "Bearer " ^ token; "x-masc-sse-instance-id", instance_id
          ; "Last-Event-ID", id ] in
        Eio.Fiber.fork ~sw (fun () ->
          ignore (Masc_http_client.get_stream ~clock ~idle_timeout_sec:3. ~url ~headers:next_headers
            ~on_response:(fun ~status ~headers ->
              ignore (Eio.Promise.try_resolve publish_next_response (status, headers)))
            ~on_chunk:(fun chunk ->
              Sse_wire.feed next_decoder chunk |> List.iter (fun (frame : Sse_wire.frame) ->
                next_payloads := frame.data :: !next_payloads;
                if String.equal frame.data {|{"type":"replacement-scope-live"}|} then
                  ignore (Eio.Promise.try_resolve publish_next_live ()))) ()));
        let next_status, next_headers = Eio.Time.with_timeout_exn clock 3.
          (fun () -> Eio.Promise.await next_response) in
        Alcotest.(check int) "replacement observer opens" 200 next_status;
        let next_scope = Masc.Mcp_server.workspace_scope state in
        let next_instance = Masc.Build_identity.runtime_instance_id ^ "."
          ^ Masc.Mcp_server.Workspace_scope_epoch.to_string next_scope.epoch in
        Alcotest.(check bool) "old workspace cursor resets" true
          (Sse_wire.decode_observer_response next_headers =
           Ok (Some { instance_id = next_instance; replay = Sse_wire.Reset Sse_wire.Instance_changed }));
        (* Model a producer that committed under the previous scope, then was
           delayed until the replacement's stream was already connected. *)
        let replay_start = Masc.Sse.current_id () in
        Masc.Sse.broadcast_to (Masc.Sse.Scoped_runtime_observers previous_scope)
          (`Assoc [ "type", `String "previous-scope-delayed";
                    "keeper_name", `String "previous-scope-only" ]);
        let replacement_scope = Masc.Sse.observer_scope ~runtime_authority:previous_authority
          ~instance_id:next_instance in
        Masc.Sse.broadcast_to (Masc.Sse.Scoped_runtime_observers replacement_scope)
          (`Assoc [ "type", `String "replacement-scope-live" ]);
        Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await next_live);
        Alcotest.(check bool) "the previous scope tail is not replayed" false
          (List.mem {|{"type":"previous-scope-tail"}|} !next_payloads);
        Alcotest.(check bool) "the previous scope's delayed event is not delivered" false
          (List.mem {|{"type":"previous-scope-delayed","keeper_name":"previous-scope-only"}|}
             !next_payloads);
        let replay = Masc.Sse.replay_after_for_session ~runtime_authority:previous_authority
          ~observer_instance_id:next_instance ~session_id:successor_id ~kind:Observer replay_start in
        Alcotest.(check bool) "replacement replay excludes the delayed previous event" false
          (List.exists (fun (delivery : Masc.Sse.delivery) ->
            Yojson.Safe.Util.member "type" delivery.payload = `String "previous-scope-delayed")
            replay.deliveries);
        Alcotest.(check bool) "replacement replay retains its own event" true
          (List.exists (fun (delivery : Masc.Sse.delivery) ->
            Yojson.Safe.Util.member "type" delivery.payload = `String "replacement-scope-live")
            replay.deliveries);
        Transport.stop_sse_session successor_id)))
;;

(* Real local login rotation, followed by each production SSE admission path.
   Restore the process credential cells and delete only this fixture's store. *)
let with_rotating_workspace_credential ~port body =
  let workspace = Filename.temp_file "tui-sse-credential" "" in
  Sys.remove workspace;
  Unix.mkdir workspace 0o700;
  let previous_env = Sys.getenv_opt Masc_tui_credential.token_env_var in
  let previous_cell = Atomic.get Http.operator_credential_cell in
  let previous_workspace = !Http.credential_workspace in
  let previous_source = !Http.operator_token_source in
  let previous_failed = !Http.failed_refresh in
  let rec remove path =
    if Sys.is_directory path then begin
      Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
    end else Sys.remove path in
  Fun.protect ~finally:(fun () ->
    Atomic.set Http.operator_credential_cell previous_cell;
    Http.credential_workspace := previous_workspace;
    Http.operator_token_source := previous_source;
    Http.failed_refresh := previous_failed;
    (match previous_env with
     | None -> Unix.unsetenv Masc_tui_credential.token_env_var
     | Some value -> Unix.putenv Masc_tui_credential.token_env_var value);
    remove workspace) (fun () ->
    Unix.unsetenv Masc_tui_credential.token_env_var;
    let mint () =
      match Auth_login.mint ~base_path:workspace ~host:"127.0.0.1" ~port
          ~agent_name:Masc_tui_credential.agent_name ~role:Masc_domain.Admin
          ~token_env_var:Masc_tui_credential.token_env_var
          ~token_lifetime:Auth_login.Long_lived () with
      | Ok report -> report.bearer_token
      | Error error -> Alcotest.fail (Masc_domain.masc_error_to_string error) in
    let original = mint () in
    Alcotest.(check bool) "the production installer adopts the original file" true
      (Http.install_operator_token ~base_path:workspace ~host:"127.0.0.1" ~port
       = Masc_tui_credential.Held);
    let expected = { identity with
      sid_base_path = Masc.Tui_decode.Canonical_path.of_path workspace;
      sid_masc_root = Masc.Tui_decode.Canonical_path.of_path (Filename.concat workspace ".masc") } in
    body ~original ~mint ~expected)
;;

let credential_subscriptions env ~port ~expected =
  let clock = Eio.Stdenv.clock env in
  [ "observer", (fun ~on_chunk ->
      ignore (Http.observe_runtime_events ~clock ~host:"127.0.0.1" ~port
        ~expected_base_path:expected.Masc.Tui_decode.sid_base_path
        ~expected_masc_root:expected.sid_masc_root ~session_id:"held-session"
        ~cursor:(Some Sse_wire.{ instance_id = "held-instance"; event_id = 17 })
        ~on_identity:ignore ~on_open:ignore ~on_chunk : (unit, Http.observer_error) result))
  ; "fleet", (fun ~on_chunk ->
      ignore (Http.observe_fleet_stream ~clock ~host:"127.0.0.1" ~port
        ~expected_workspace:expected ~on_chunk : (unit, Http.observer_error) result))
  ; "system-log", (fun ~on_chunk ->
      ignore (Http.observe_system_log_stream ~clock ~host:"127.0.0.1" ~port
        ~instance:"held-instance" ~level:"info" ~since_seq:17 ~limit:10 ~on_chunk () : string))
  ]
;;

let check_sse_credential_rotation env ~first_status ~second_status ~requests ~delivered =
  List.iter (fun index ->
    let observed = ref [] and rotate = ref None in
    let original = ref None and replacement = ref None in
    let handler reqd =
      let request = Httpun.Reqd.request reqd in
      let headers = request.Httpun.Request.headers in
      let authorization = Httpun.Headers.get headers "authorization" in
      let first = !observed = [] in
      observed := (request.target, authorization,
        List.map (Httpun.Headers.get headers)
          ["mcp-session-id"; "last-event-id"; "x-masc-sse-instance-id"]) :: !observed;
      if first then begin
        (match !rotate with
         | None -> Alcotest.fail "credential rotation was not installed"
         | Some mint -> replacement := Some ("Bearer " ^ mint ()))
      end;
      let status = if first then first_status else second_status in
      if status = `OK then
        stream_response ~receipts:[receipt; "x-masc-sse-instance-id", "held-instance";
          "x-masc-sse-replay", "resumed"] ["data: accepted\n\n"] reqd
      else json_response ~status "admission refused" reqd in
    with_server env ~handler (fun ~port ->
      with_rotating_workspace_credential ~port (fun ~original:held ~mint ~expected ->
        original := Some ("Bearer " ^ held);
        rotate := Some mint;
        let label, subscribe = List.nth (credential_subscriptions env ~port ~expected) index in
        let bytes = Buffer.create 32 in
        subscribe ~on_chunk:(Buffer.add_string bytes);
        Alcotest.(check int) (label ^ ": admission requests") requests (List.length !observed);
        Alcotest.(check string) (label ^ ": only accepted stream bytes reach the consumer")
          (if delivered then "data: accepted\n\n" else "") (Buffer.contents bytes);
        match List.rev !observed with
        | [(target, bearer, cursor)] ->
            Alcotest.(check bool) (label ^ ": initial bearer") true (bearer = !original);
            Alcotest.(check bool) (label ^ ": no refresh after non-401 or delivered bytes") true
              (Http.operator_token () = Some held);
            ignore (target, cursor)
        | [(target, bearer, cursor); (retried_target, retried_bearer, retried_cursor)] ->
            Alcotest.(check bool) (label ^ ": refused request held the old bearer") true
              (bearer = !original);
            Alcotest.(check bool) (label ^ ": retry adopts the actual new workspace bearer") true
              (retried_bearer = !replacement && retried_bearer <> bearer);
            Alcotest.(check string) (label ^ ": exact target retained") target retried_target;
            Alcotest.(check (list (option string))) (label ^ ": session and cursor retained")
              cursor retried_cursor
        | [] | _ :: _ -> Alcotest.fail "unexpected admission history"))) [0; 1; 2]
;;

let test_sse_admission_401_adopts_rotated_workspace_credential env =
  check_sse_credential_rotation env ~first_status:`Unauthorized ~second_status:`OK
    ~requests:2 ~delivered:true
;;

let test_sse_admission_retry_does_not_loop_on_second_401 env =
  check_sse_credential_rotation env ~first_status:`Unauthorized ~second_status:`Unauthorized
    ~requests:2 ~delivered:false
;;

let test_sse_forbidden_does_not_replace_credential env =
  check_sse_credential_rotation env ~first_status:`Forbidden ~second_status:`OK
    ~requests:1 ~delivered:false
;;

let test_sse_delivered_stream_does_not_refresh_or_replay env =
  check_sse_credential_rotation env ~first_status:`OK ~second_status:`OK
    ~requests:1 ~delivered:true
;;

let test_sse_admission_cancellation_is_not_a_refusal env =
  List.iter (fun index ->
    with_raw_peer env ~status:401 ~attest:false ~truncate:false
      (fun ~port ~closed ~writes:_ ->
        let label, subscribe = List.nth
          (credential_subscriptions env ~port ~expected:identity) index in
        (match
           try
             Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 0.05
               (fun () -> subscribe ~on_chunk:(fun _ -> Alcotest.fail "refusal bytes escaped"));
             `Returned
           with Eio.Time.Timeout -> `Cancelled
         with
         | `Cancelled -> ()
         | `Returned -> Alcotest.fail (label ^ ": cancellation became a completed outcome"));
        wait_for_peer_close env closed)) [0; 1; 2]
;;

let test_observer_names_controlled_machine env =
  let target = ref "" in
  let handler reqd =
    target := (Httpun.Reqd.request reqd).Httpun.Request.target;
    stream_response ~receipts:[ receipt ] [ "data: {}\n\n" ] reqd
  in
  with_server env ~handler (fun ~port ->
    let result = Http.observe_runtime_events_with_machine ~clock:(Eio.Stdenv.clock env)
        ~machine:(Some Masc.Machine_lane.Msx)
        ~on_identity:(fun _ -> ()) ~expected_base_path:identity.sid_base_path
        ~expected_masc_root:identity.sid_masc_root ~host:"127.0.0.1" ~port
        ~session_id:"observer-machine" ~cursor:None ~on_open:(fun _ -> ())
        ~on_chunk:(fun _ -> ()) in
    Alcotest.(check bool) "the controlled observer opens" true (Result.is_ok result);
    Alcotest.(check (option string)) "the query names only the controlled machine"
      (Some "msx") (Uri.get_query_param (Uri.of_string !target) "machine"))
;;

let () =
  let case name test = Alcotest.test_case name `Quick (with_env test) in
  Alcotest.run
    "Tui_execute_stream_http"
    [ ( "the request"
      , [ case
            "an attested stream is read to its end"
            test_an_attested_stream_is_read_to_its_end
        ; case
            "a keeper name is encoded in the path"
            test_a_keeper_name_is_encoded_in_the_path
        ; case "a Goal timeline keeps its query ID and workspace"
            test_goal_timeline_query_preserves_the_requested_id
        ] )
    ; ( "what is refused"
      , [ case
            "a stream without the receipt is refused before a byte is read"
            test_a_stream_without_the_receipt_is_refused_before_a_byte_is_read
        ; case "execute rejects invalid SSE responses before reading"
            test_execute_rejects_invalid_sse_responses_before_reading
        ; case
            "a workspace mismatch is refused with its status"
            test_a_workspace_mismatch_is_refused_with_its_status
        ; case "a disconnected refusal body keeps its status" test_refusal_body_disconnect_keeps_the_status
        ; case "a dribbling refusal has a whole-body deadline" test_dribbling_refusal_has_a_whole_body_deadline
        ; case "the refusal deadline does not end a successful stream"
            test_the_refusal_deadline_does_not_end_a_successful_stream
        ; case "cancelling a refusal body still cancels the request"
            test_cancelling_a_refusal_body_still_cancels_the_request
        ] )
    ; ( "observer replay"
      , [ case "standalone Observer delivers a waiting invalidation and inventory read"
            test_standalone_observer_delivers_waiting_inventory_changes
        ; case "standalone Observer reconnects with response identifiers"
            test_standalone_observer_reconnects_with_response_identifiers
        ; case "standalone Observer window survives connection cleanup"
            test_standalone_observer_window_survives_connection_cleanup
        ; case "standalone guard retains later times after reversed completion"
            test_standalone_guard_retains_later_time_after_reversed_completion
        ; case "standalone guard expires each boundary entry once"
            test_standalone_guard_expires_each_boundary_entry_once
        ; case "standalone Observer keeps auth and supplied-session checks"
            test_standalone_observer_keeps_auth_and_supplied_session_checks
        ; case "invalid handshake is not opened or read" test_observer_rejects_bad_replay_before_delivering_bytes
        ; case "unusable replay retries without the requested cursor" test_observer_retries_without_cursor
        ; case "valid and unadvertised live streams still open" test_observer_accepts_valid_and_unadvertised_live_streams
        ; case "a controlled observer names its machine" test_observer_names_controlled_machine
        ; case "observer requires the workspace receipt" test_observer_requires_workspace_receipt
        ; case "unknown and non-observer machine queries are rejected" test_mcp_rejects_unknown_machine_and_non_observer_machine
        ; case "identity requires scoped admission" test_observer_identity_requires_scoped_admission
        ; case "workspace refusal differs from session conflict" test_observer_workspace_refusal_is_not_a_session_conflict
        ; case "MCP rejects duplicate cursor headers" test_mcp_rejects_duplicate_cursors_before_registration
        ; case "MCP refuses foreign and retired workspaces" test_mcp_observer_refuses_foreign_and_retired_workspaces
        ; case "retired observer cannot close its successor" test_retired_observer_close_keeps_successor
        ; case "Play observer reconnect keeps replacement presence" test_play_observer_reconnect_keeps_replacement_presence
        ; case "stale reconnect cannot replace its successor" test_stale_reconnect_cannot_replace_successor
        ; case "disconnect before lease installation cleans up" test_disconnect_before_lease_install_cleans_up
        ; case "aborted replacement cleans predecessor presence" test_aborted_replacement_cleans_predecessor_presence
        ; case "readiness loss cleans predecessor presence" test_readiness_loss_cleans_predecessor_presence
        ; case "ping renews Play presence" test_ping_scheduler_renews_play_presence
        ; case "transport disconnect finishes Leave before cancellation" test_transport_disconnect_finishes_leave_before_cancellation
        ; case "generic replacement disconnects predecessor once" test_generic_replacement_disconnects_predecessor_once
        ; case "MCP resets a future cursor and sends live events" test_mcp_future_cursor_resets_before_live_delivery
        ] )
    ; ( "SSE response"
      , [ case "both subscriptions validate status and media type" test_sse_status_and_content_type_gate
        ; case "HTTP refusals keep status and body" test_sse_http_refusals_keep_status_and_body
        ; case "admission 401 adopts a rotated workspace credential"
            test_sse_admission_401_adopts_rotated_workspace_credential
        ; case "a second admission 401 is returned without a retry loop"
            test_sse_admission_retry_does_not_loop_on_second_401
        ; case "a 403 never replaces the held credential"
            test_sse_forbidden_does_not_replace_credential
        ; case "delivered stream bytes never trigger credential replay"
            test_sse_delivered_stream_does_not_refresh_or_replay
        ; case "admission cancellation remains cancellation"
            test_sse_admission_cancellation_is_not_a_refusal
        ; case "fleet requires the workspace receipt" test_fleet_requires_workspace_receipt
        ; case "fleet route attests its admitted workspace" test_fleet_route_attests_its_admitted_workspace
        ; case "registered fleet route replaces its scope" test_registered_fleet_route_replaces_its_scope ] )
    ]
;;
