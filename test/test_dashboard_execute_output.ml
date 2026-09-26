open Alcotest

module EO = Dashboard_execute_output
module Router = Masc.Http_server_eio.Router

let status_ok = `Assoc [ "kind", `String "exit"; "code", `Int 0 ]

let with_fresh f () =
  EO.reset_for_testing ();
  f ()

let test_no_task_event () =
  let json = EO.event_json ~keeper_name:"alpha" in
  let open Yojson.Safe.Util in
  check string "type" "no_task" (json |> member "type" |> to_string);
  check string "keeper" "alpha" (json |> member "keeper" |> to_string);
  check bool "closed" true (json |> member "closed" |> to_bool)

let test_snapshot_merges_completed_output () =
  EO.inject_for_testing
    ~keeper_name:"Alpha"
    ~task_id:"task-1"
    ~stdout:"first\n"
    ~stderr:""
    ~status:status_ok
    ();
  EO.inject_for_testing
    ~keeper_name:"alpha"
    ~task_id:"task-2"
    ~stdout:"second\n"
    ~stderr:"err\n"
    ~status:status_ok
    ();
  match EO.snapshot ~keeper_name:"alpha" with
  | None -> fail "expected snapshot"
  | Some snapshot ->
    check string "keeper normalized" "alpha" snapshot.keeper;
    check (option string) "latest task" (Some "task-2") snapshot.task_id;
    check int "task count" 2 snapshot.task_count;
    check string "stdout" "first\nsecond\n" snapshot.stdout_since;
    check string "stderr" "err\n" snapshot.stderr_since;
    check int "stdout bytes" 13 snapshot.since_stdout;
    check int "stderr bytes" 4 snapshot.since_stderr;
    check bool "closed" true snapshot.closed

let test_snapshot_json_shape () =
  EO.inject_for_testing
    ~keeper_name:"alpha"
    ~task_id:"task-123"
    ~generated_at:1000.0
    ~stdout:"ok\n"
    ~stderr:""
    ~status:status_ok
    ();
  let json = EO.event_json ~keeper_name:"alpha" in
  let open Yojson.Safe.Util in
  check string "type" "snapshot" (json |> member "type" |> to_string);
  check string "task" "task-123" (json |> member "task_id" |> to_string);
  check string "stdout" "ok\n" (json |> member "stdout_since" |> to_string);
  check bool "closed" true (json |> member "closed" |> to_bool);
  check int "status code" 0 (json |> member "status" |> member "code" |> to_int)

let test_snapshot_line_ring_shape () =
  EO.inject_for_testing
    ~keeper_name:"alpha"
    ~task_id:"task-123"
    ~generated_at:1000.0
    ~stdout:"ok\nsecond"
    ~stderr:"warn\n"
    ~status:status_ok
    ();
  let lines = EO.output_lines_for_testing ~keeper_name:"alpha" in
  check int "line count" 3 (List.length lines);
  check string "first stream" "stdout" (List.hd lines).stream;
  check string "first text" "ok" (List.hd lines).text;
  let json = EO.event_json ~keeper_name:"alpha" in
  let open Yojson.Safe.Util in
  let json_lines = json |> member "lines" |> to_list in
  check int "json line count" 3 (List.length json_lines);
  check string "json line text" "ok" (List.hd json_lines |> member "text" |> to_string);
  check int "json line ts" 1000000 (List.hd json_lines |> member "ts_ms" |> to_int)

let hangul_line count = String.concat "" (List.init count (fun _ -> "\xea\xb0\x80"))

(* A 9,000-byte line of Hangul is longer than one row (4,096 bytes), and
   4,096 is not a multiple of 3. The old row kept a character-safe prefix and
   dropped the other 4,904 bytes without a mark. *)
let test_long_line_continues_in_next_rows () =
  let line = hangul_line 3_000 in
  EO.inject_for_testing
    ~keeper_name:"alpha"
    ~stdout:(line ^ "\n")
    ~stderr:""
    ~status:status_ok
    ();
  let rows = EO.output_lines_for_testing ~keeper_name:"alpha" in
  check int "the line takes three rows" 3 (List.length rows);
  List.iteri
    (fun index (row : EO.output_line) ->
       check bool
         (Printf.sprintf "row %d decodes as UTF-8" index)
         true
         (String_util.is_valid_utf8 row.text);
       check bool
         (Printf.sprintf "row %d fits one row" index)
         true
         (String.length row.text <= 4096))
    rows;
  check string "the rows spell the whole line" line
    (String.concat "" (List.map (fun (row : EO.output_line) -> row.text) rows))

(* 270,000 bytes of Hangul, and the snapshot keeps the last 262,144: the ring
   starts on the third byte of a syllable. That byte is skipped and counted as
   dropped, so the text decodes and dropped + shown still covers the total. *)
let test_snapshot_tail_starts_on_a_character () =
  EO.inject_for_testing
    ~keeper_name:"alpha"
    ~stdout:(hangul_line 90_000)
    ~stderr:""
    ~status:status_ok
    ();
  match EO.snapshot ~keeper_name:"alpha" with
  | None -> fail "expected snapshot"
  | Some snapshot ->
    check bool "stdout_since decodes as UTF-8" true
      (String_util.is_valid_utf8 snapshot.stdout_since);
    check int "total bytes" 270_000 snapshot.since_stdout;
    check int "the partial character counts as dropped" 7_857
      snapshot.bytes_dropped_stdout;
    check int "dropped + shown = total" snapshot.since_stdout
      (snapshot.bytes_dropped_stdout + String.length snapshot.stdout_since)

let test_live_tail_subscriber_receives_line_and_close () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.inject_for_testing
             ~keeper_name:"alpha"
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
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"alpha" ~task_id:(Some "task-stream");
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
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"alpha" ~task_id:(Some "task-stream");
           (* drain task_opened *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           EO.append_stream_chunk ~keeper_name:"alpha" ~stream:`Stdout "hello\nworld";
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
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"alpha" ~task_id:(Some "task-stream");
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           EO.record_stream_end
             ~keeper_name:"alpha"
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
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.record_stream_start ~keeper_name:"alpha" ~task_id:(Some "task-stream");
           (* task_opened *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber)
           in
           EO.append_stream_chunk ~keeper_name:"alpha" ~stream:`Stdout " streamed line\n";
           (* line event from chunk *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber)
           in
           EO.record_stream_end
             ~keeper_name:"alpha"
             ~task_id:(Some "task-stream")
             ~status:status_ok;
           EO.record_completed
             ~keeper_name:"alpha"
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
           (* The streamed line is retained once: record_completed with
              [~streamed:true] does not log it again. *)
           check
             int
             "retained lines"
             1
             (List.length (EO.output_lines_for_testing ~keeper_name:"alpha"));
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

let numbered_lines ~count =
  List.init count (fun i -> Printf.sprintf "row-%05d\n" (i + 1)) |> String.concat ""

let take_events env subscriber ~count =
  Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
    List.init count (fun _ -> EO.take_event subscriber |> EO.stream_event_json))

let json_type json = Yojson.Safe.Util.(json |> member "type" |> to_string)

let json_seq json = Yojson.Safe.Util.(json |> member "seq" |> to_int)

let line_text json =
  Yojson.Safe.Util.(json |> member "line" |> member "text" |> to_string)

(* One captured stdout arrives as a single chunk. Every row of it must reach
   a subscriber that has not read anything yet, in order. *)
let test_large_chunk_reaches_undrained_subscriber_whole () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           let row_count = 1000 in
           EO.record_stream_start ~keeper_name:"alpha" ~task_id:(Some "task-big");
           EO.append_stream_chunk
             ~keeper_name:"alpha"
             ~stream:`Stdout
             (numbered_lines ~count:row_count);
           EO.record_stream_end
             ~keeper_name:"alpha"
             ~task_id:(Some "task-big")
             ~status:status_ok;
           let events = take_events env subscriber ~count:(row_count + 2) in
           let types = List.map json_type events in
           check string "first event" "task_opened" (List.hd types);
           check string "last event" "task_closed" (List.nth types (row_count + 1));
           check
             int
             "no gap"
             0
             (List.length (List.filter (String.equal "gap") types));
           let lines = List.filter (fun json -> json_type json = "line") events in
           check int "every row" row_count (List.length lines);
           check
             (list string)
             "rows in order"
             (List.init row_count (fun i -> Printf.sprintf "row-%05d" (i + 1)))
             (List.map line_text lines);
           check
             (list int)
             "consecutive numbers"
             (List.init (row_count + 2) (fun i -> i + 1))
             (List.map json_seq events)))

(* A subscriber further behind than the retained log is told which numbers
   it missed, then receives every retained row. *)
let test_subscriber_behind_retained_log_receives_gap () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           let evicted = 10 in
           let row_count = EO.event_log_capacity + evicted in
           EO.append_stream_chunk
             ~keeper_name:"alpha"
             ~stream:`Stdout
             (numbered_lines ~count:row_count);
           let events =
             take_events env subscriber ~count:(EO.event_log_capacity + 1)
           in
           let open Yojson.Safe.Util in
           let gap = List.hd events in
           check string "gap first" "gap" (json_type gap);
           check int "missing from" 1 (gap |> member "missing_from_seq" |> to_int);
           check int "missing to" evicted (gap |> member "missing_to_seq" |> to_int);
           check int "missing count" evicted (gap |> member "missing_count" |> to_int);
           let lines = List.tl events in
           check
             (list string)
             "retained rows in order"
             (List.init EO.event_log_capacity (fun i ->
                Printf.sprintf "row-%05d" (evicted + i + 1)))
             (List.map line_text lines);
           check
             int
             "snapshot rows"
             EO.event_log_capacity
             (List.length (EO.output_lines_for_testing ~keeper_name:"alpha"))))

(* A line logged between subscribe and the first payload is in the snapshot,
   so the live tail must not deliver it again. *)
let test_initial_snapshot_starts_live_tail_after_it () =
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () ->
           EO.inject_for_testing
             ~keeper_name:"alpha"
             ~task_id:"task-1"
             ~stdout:"before snapshot\n"
             ~stderr:""
             ~status:status_ok
             ();
           let initial = EO.initial_event_json subscriber in
           let open Yojson.Safe.Util in
           check string "snapshot" "snapshot" (json_type initial);
           check int "last seq" 2 (initial |> member "last_seq" |> to_int);
           check
             (list int)
             "line numbers"
             [ 1 ]
             (initial |> member "lines" |> to_list
              |> List.map (fun line -> line |> member "seq" |> to_int));
           EO.append_stream_chunk ~keeper_name:"alpha" ~stream:`Stdout "after snapshot\n";
           let next =
             Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
               EO.take_event subscriber |> EO.stream_event_json)
           in
           check string "next is new line" "after snapshot" (line_text next);
           check int "next number" 3 (json_seq next)))

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
        "/api/dashboard/execute-output/alpha"
        "/api/dashboard/execute-output/";
      check_route
        "v1 route"
        "/api/v1/dashboard/execute-output/alpha"
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
            "long line continues in next rows"
            `Quick
            (with_fresh test_long_line_continues_in_next_rows)
        ; test_case
            "snapshot tail starts on a character"
            `Quick
            (with_fresh test_snapshot_tail_starts_on_a_character)
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
        ; test_case
            "large chunk reaches undrained subscriber whole"
            `Quick
            (with_fresh test_large_chunk_reaches_undrained_subscriber_whole)
        ; test_case
            "subscriber behind retained log receives gap"
            `Quick
            (with_fresh test_subscriber_behind_retained_log_receives_gap)
        ; test_case
            "initial snapshot starts live tail after it"
            `Quick
            (with_fresh test_initial_snapshot_starts_live_tail_after_it)
        ; test_case "sse frame" `Quick test_sse_frame
        ; test_case "routes match keeper path" `Quick test_dashboard_routes_match_keeper_path
        ] )
    ]
