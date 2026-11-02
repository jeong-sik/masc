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
  ; sid_binary_commit_age_s = None
  ; sid_base_path = Decode.Canonical_path.of_path "/owned-workspace"
  ; sid_masc_root = Decode.Canonical_path.of_path "/owned-workspace/.masc"
  ; sid_executable_in_worktree = None
  ; sid_state_ready = Some true
  ; sid_uptime = None
  ; sid_sse_clients = None
  ; sid_gc = None
  ; sid_scheduler = None
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
    with_server env ~handler:(stream_response ~receipts:headers [ "data: {}\n\n" ]) (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
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
    with_server env ~handler:(stream_response ~receipts:headers [ "data: {}\n\n" ]) (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
          ~host:"127.0.0.1" ~port ~session_id:"observer-test" ~cursor:(Some requested)
          ~on_open:(fun _ -> incr opens) ~on_chunk:(fun _ -> incr chunks) in
      (match result with
       | Error (Http.Retry_without_cursor (cursor, _)) ->
           Alcotest.(check bool) (label ^ ": retry names requested cursor") true (cursor = requested)
       | Error (Http.Invalid_handshake detail | Http.Transport_failed detail) ->
           Alcotest.failf "%s: %s" label detail
       | Error (Http.Http_refused { status; _ }) -> Alcotest.failf "%s: HTTP %d" label status
       | Ok () -> Alcotest.failf "%s: accepted" label);
      Alcotest.(check int) (label ^ ": no open callback") 0 !opens;
      Alcotest.(check int) (label ^ ": no body callback") 0 !chunks)) cases
;;

let test_observer_accepts_valid_and_unadvertised_live_streams env =
  let requested = Some Sse_wire.{ instance_id = "process-a"; event_id = 50 } in
  List.iter (fun (label, cursor, headers) ->
    with_server env ~handler:(stream_response ~receipts:headers [ "data: {}\n\n" ]) (fun ~port ->
      let opens = ref 0 and chunks = ref 0 in
      let result = Http.observe_runtime_events ~clock:(Eio.Stdenv.clock env)
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
    ; verify_mcp_auth = admit
    ; verify_mcp_observer_stream_auth = admit
    ; verify_operator_mcp_auth = admit
    ; verify_seat_mcp_auth = admit
    } in
  let handler reqd =
    let request = Httpun.Reqd.request reqd in
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

let test_mcp_future_cursor_resets_before_live_delivery env =
  let module Transport = Server_mcp_transport_http in
  let workspace = Masc_test_deps.setup_test_workspace () in
  let session_id = "observer-future-test-" ^ string_of_int (Random.bits ()) in
  let auth = Masc_test_deps.make_sse_auth workspace "future-observer" in
  let token = Option.get auth.Masc.Sse.token in
  ignore (Masc.Session.McpSessionStore.get_or_create ~id:session_id ());
  Fun.protect
    ~finally:(fun () ->
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
      let deps : Transport.deps =
        { get_origin = (fun _ -> "")
        ; cors_headers = (fun _ -> [])
        ; auth_token_from_request = (fun _ -> None)
        ; is_ready = (fun () -> true)
        ; get_runtime_result = (fun () -> Ok runtime)
        ; get_base_path = (fun () -> workspace)
        ; verify_mcp_auth = admit
        ; verify_mcp_observer_stream_auth = admit
        ; verify_operator_mcp_auth = admit
        ; verify_seat_mcp_auth = admit
        } in
      let handler reqd =
        let request = Httpun.Reqd.request reqd in
        Server_request_authority.with_current authority (fun () ->
          Transport.handle_get_mcp ~deps ~sse_kind:Masc.Sse.Observer request reqd) in
      with_server env ~handler (fun ~port ->
        let response, publish_response = Eio.Promise.create () in
        let event, publish_event = Eio.Promise.create () in
        let decoder = Sse_wire.create_decoder () in
        let url = Printf.sprintf "http://127.0.0.1:%d/mcp?sse_kind=observer" port in
        let headers =
          [ "Accept", "text/event-stream"
          ; "Mcp-Session-Id", session_id
          ; "Authorization", "Bearer " ^ token
          ; "x-masc-sse-instance-id", Masc.Build_identity.runtime_instance_id
          ; "Last-Event-ID", string_of_int max_int
          ] in
        Eio.Fiber.fork ~sw (fun () ->
          ignore (Masc_http_client.get_stream ~clock:(Eio.Stdenv.clock env)
            ~idle_timeout_sec:3. ~url ~headers
            ~on_response:(fun ~status ~headers ->
              ignore (Eio.Promise.try_resolve publish_response (status, headers)))
            ~on_chunk:(fun chunk ->
              Sse_wire.feed decoder chunk |> List.iter (fun (frame : Sse_wire.frame) ->
                Option.iter (fun id -> ignore (Eio.Promise.try_resolve publish_event id)) frame.id)) ()));
        let clock = Eio.Stdenv.clock env in
        let status, headers = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await response) in
        Alcotest.(check int) "MCP stream opens" 200 status;
        let handshake = Sse_wire.decode_observer_response headers in
        let expected : Sse_wire.observer_handshake =
          { instance_id = Masc.Build_identity.runtime_instance_id
          ; replay = Sse_wire.Reset Sse_wire.Cursor_ahead } in
        Alcotest.(check bool) "same-instance future cursor is reset" true
          (handshake = Ok (Some expected));
        Masc.Sse.broadcast_to Masc.Sse.Observers (`Assoc [ "type", `String "future-reset-live" ]);
        let id = Eio.Time.with_timeout_exn clock 3. (fun () -> Eio.Promise.await event) in
        Alcotest.(check bool) "a lower live event is delivered" true
          (match int_of_string_opt id with Some id -> id < max_int | None -> false);
        Transport.stop_sse_session session_id)))
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
      , [ case "invalid handshake is not opened or read" test_observer_rejects_bad_replay_before_delivering_bytes
        ; case "unusable replay retries without the requested cursor" test_observer_retries_without_cursor
        ; case "valid and unadvertised live streams still open" test_observer_accepts_valid_and_unadvertised_live_streams
        ; case "MCP rejects duplicate cursor headers" test_mcp_rejects_duplicate_cursors_before_registration
        ; case "MCP resets a future cursor and sends live events" test_mcp_future_cursor_resets_before_live_delivery
        ] )
    ; ( "SSE response"
      , [ case "both subscriptions validate status and media type" test_sse_status_and_content_type_gate
        ; case "HTTP refusals keep status and body" test_sse_http_refusals_keep_status_and_body
        ; case "fleet requires the workspace receipt" test_fleet_requires_workspace_receipt
        ; case "fleet route attests its admitted workspace" test_fleet_route_attests_its_admitted_workspace ] )
    ]
;;
