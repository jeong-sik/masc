open Alcotest

module EO = Dashboard_execute_output
module Router = Masc.Http_server_eio.Router

let status_ok = `Assoc [ "kind", `String "exit"; "code", `Int 0 ]

let with_fresh f () =
  EO.reset_for_testing ();
  f ()

let test_no_task_event () =
  let json = EO.event_json ~keeper_name:"sangsu" in
  let open Yojson.Safe.Util in
  check string "type" "no_task" (json |> member "type" |> to_string);
  check string "keeper" "sangsu" (json |> member "keeper" |> to_string);
  check bool "closed" true (json |> member "closed" |> to_bool)

let test_snapshot_merges_completed_output () =
  EO.inject_for_testing
    ~keeper_name:"Sangsu"
    ~task_id:"task-1"
    ~stdout:"first\n"
    ~stderr:""
    ~status:status_ok
    ();
  EO.inject_for_testing
    ~keeper_name:"sangsu"
    ~task_id:"task-2"
    ~stdout:"second\n"
    ~stderr:"err\n"
    ~status:status_ok
    ();
  match EO.snapshot ~keeper_name:"sangsu" with
  | None -> fail "expected snapshot"
  | Some snapshot ->
    check string "keeper normalized" "sangsu" snapshot.keeper;
    check (option string) "latest task" (Some "task-2") snapshot.task_id;
    check int "task count" 2 snapshot.task_count;
    check string "stdout" "first\nsecond\n" snapshot.stdout_since;
    check string "stderr" "err\n" snapshot.stderr_since;
    check int "stdout bytes" 13 snapshot.since_stdout;
    check int "stderr bytes" 4 snapshot.since_stderr;
    check bool "closed" true snapshot.closed

let test_snapshot_json_shape () =
  EO.inject_for_testing
    ~keeper_name:"sangsu"
    ~task_id:"task-123"
    ~generated_at:1000.0
    ~stdout:"ok\n"
    ~stderr:""
    ~status:status_ok
    ();
  let json = EO.event_json ~keeper_name:"sangsu" in
  let open Yojson.Safe.Util in
  check string "type" "snapshot" (json |> member "type" |> to_string);
  check string "task" "task-123" (json |> member "task_id" |> to_string);
  check string "stdout" "ok\n" (json |> member "stdout_since" |> to_string);
  check bool "closed" true (json |> member "closed" |> to_bool);
  check int "status code" 0 (json |> member "status" |> member "code" |> to_int)

let test_snapshot_line_ring_shape () =
  EO.inject_for_testing
    ~keeper_name:"sangsu"
    ~task_id:"task-123"
    ~generated_at:1000.0
    ~stdout:"ok\nsecond"
    ~stderr:"warn\n"
    ~status:status_ok
    ();
  let lines = EO.output_lines_for_testing ~keeper_name:"sangsu" in
  check int "line count" 3 (List.length lines);
  check string "first stream" "stdout" (List.hd lines).stream;
  check string "first text" "ok" (List.hd lines).text;
  let json = EO.event_json ~keeper_name:"sangsu" in
  let open Yojson.Safe.Util in
  let json_lines = json |> member "lines" |> to_list in
  check int "json line count" 3 (List.length json_lines);
  check string "json line text" "ok" (List.hd json_lines |> member "text" |> to_string);
  check int "json line ts" 1000000 (List.hd json_lines |> member "ts_ms" |> to_int)

let test_live_tail_subscriber_receives_line_and_close () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"sangsu" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.inject_for_testing
             ~keeper_name:"sangsu"
             ~task_id:"task-123"
             ~generated_at:1000.0
             ~stdout:"ok\n"
             ~stderr:""
             ~status:status_ok
             ();
           let take_json () =
             EO.take_event subscriber |> EO.stream_event_json
           in
           let line_json =
             Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 take_json
           in
           let closed_json =
             Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 take_json
           in
           let open Yojson.Safe.Util in
           check string "line type" "line" (line_json |> member "type" |> to_string);
           check
             string
             "line text"
             "ok"
             (line_json |> member "line" |> member "text" |> to_string);
           check
             string
             "closed type"
             "task_closed"
             (closed_json |> member "type" |> to_string);
           check bool "closed" true (closed_json |> member "closed" |> to_bool)))

let test_stream_start_emits_task_opened () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"sangsu" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"sangsu" ~task_id:(Some "task-stream");
           let json =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           let open Yojson.Safe.Util in
           check string "type" "task_opened" (json |> member "type" |> to_string);
           check string "task" "task-stream" (json |> member "task_id" |> to_string);
           check bool "closed" false (json |> member "closed" |> to_bool)))

let test_stream_chunk_emits_line () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"sangsu" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"sangsu" ~task_id:(Some "task-stream");
           (* drain task_opened *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           EO.append_stream_chunk ~keeper_name:"sangsu" ~stream:`Stdout "hello\nworld";
           let line1 =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           let line2 =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           let open Yojson.Safe.Util in
           check string "first type" "line" (line1 |> member "type" |> to_string);
           check
             string
             "first text"
             "hello"
             (line1 |> member "line" |> member "text" |> to_string);
           check string "first stream" "stdout" (line1 |> member "line" |> member "stream" |> to_string);
           check string "second type" "line" (line2 |> member "type" |> to_string);
           check
             string
             "second text"
             "world"
             (line2 |> member "line" |> member "text" |> to_string)))

let test_stream_end_emits_task_closed () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"sangsu" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"sangsu" ~task_id:(Some "task-stream");
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           EO.record_stream_end
             ~keeper_name:"sangsu"
             ~task_id:(Some "task-stream")
             ~status:status_ok;
           let closed_json =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           let open Yojson.Safe.Util in
           check
             string
             "type"
             "task_closed"
             (closed_json |> member "type" |> to_string);
           check bool "closed" true (closed_json |> member "closed" |> to_bool);
           check int "status code" 0 (closed_json |> member "status" |> member "code" |> to_int)))

let test_stream_completed_does_not_duplicate_events () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"sangsu" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"sangsu" ~task_id:(Some "task-stream");
           (* task_opened *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber)
           in
           EO.append_stream_chunk ~keeper_name:"sangsu" ~stream:`Stdout " streamed line\n";
           (* line event from chunk *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber)
           in
           EO.record_stream_end
             ~keeper_name:"sangsu"
             ~task_id:(Some "task-stream")
             ~status:status_ok;
           EO.record_completed
             ~keeper_name:"sangsu"
             ~task_id:(Some "task-stream")
             ~stdout:" streamed line\n"
             ~stderr:""
             ~status:status_ok
             ~streamed:true
             ();
           (* record_stream_end emitted task_closed; record_completed with
              [~streamed:true] must not emit additional line or closed events. *)
           let closed_json =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           let open Yojson.Safe.Util in
           check
             string
             "type"
             "task_closed"
             (closed_json |> member "type" |> to_string);
           (* Subscriber queue should now be empty because record_completed
              with [~streamed:true] does not emit line events. *)
           try
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               0.1
               (fun () -> EO.take_event subscriber |> ignore);
             fail "unexpected extra event after streamed completion"
           with
           | Eio.Time.Timeout -> ()))

let test_sse_frame () =
  let frame = EO.sse_frame (`Assoc [ "type", `String "snapshot" ]) in
  check bool "event header" true (String.starts_with ~prefix:"event: output\n" frame);
  check bool "data line" true (String.contains frame '{');
  check bool "terminator" true (String.ends_with ~suffix:"\n\n" frame)

let test_dashboard_routes_match_keeper_path () =
  Eio_main.run (fun env ->
    Eio.Switch.run (fun sw ->
      let routes =
        Server_routes_http_routes_dashboard.add_routes
          ~sw
          ~clock:(Eio.Stdenv.clock env)
          (Router.create ())
      in
      let check_route label path expected =
        let request = Httpun.Request.create `GET path in
        match Router.resolve routes request with
        | `Matched route -> check string label expected route.path
        | `Method_not_allowed -> fail (label ^ " returned method_not_allowed")
        | `Not_found -> fail (label ^ " returned not_found")
      in
      check_route
        "legacy route"
        "/api/dashboard/execute-output/sangsu"
        "/api/dashboard/execute-output/";
      check_route
        "v1 route"
        "/api/v1/dashboard/execute-output/sangsu"
        "/api/v1/dashboard/execute-output/"))

let () =
  run
    "Dashboard_execute_output"
    [ ( "events"
      , [ test_case "no task event" `Quick (with_fresh test_no_task_event)
        ; test_case
            "snapshot merges completed output"
            `Quick
            (with_fresh test_snapshot_merges_completed_output)
        ; test_case "snapshot json shape" `Quick (with_fresh test_snapshot_json_shape)
        ; test_case "snapshot line ring shape" `Quick (with_fresh test_snapshot_line_ring_shape)
        ; test_case
            "live tail subscriber receives line and close"
            `Quick
            (with_fresh test_live_tail_subscriber_receives_line_and_close)
        ; test_case "stream start emits task_opened" `Quick (with_fresh test_stream_start_emits_task_opened)
        ; test_case "stream chunk emits line" `Quick (with_fresh test_stream_chunk_emits_line)
        ; test_case "stream end emits task_closed" `Quick (with_fresh test_stream_end_emits_task_closed)
        ; test_case "stream completed does not duplicate events"
            `Quick
            (with_fresh test_stream_completed_does_not_duplicate_events)
        ; test_case "sse frame" `Quick test_sse_frame
        ; test_case "routes match keeper path" `Quick test_dashboard_routes_match_keeper_path
        ] )
    ]
