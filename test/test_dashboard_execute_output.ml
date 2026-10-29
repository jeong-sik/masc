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
  check int "json includes the close status" 4 (List.length json_lines);
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
           EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "task-stream");
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
           EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "task-stream");
           (* drain task_opened *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stdout "hello\nworld";
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
           EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "task-stream");
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber |> EO.stream_event_json)
           in
           EO.record_stream_end ~stream_id:1
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
           EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "task-stream");
           (* task_opened *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber)
           in
           EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stdout " streamed line\n";
           (* line event from chunk *)
           let _ =
             Eio.Time.with_timeout_exn
               (Eio.Stdenv.clock env)
               1.0
               (fun () -> EO.take_event subscriber)
           in
           EO.record_stream_end ~stream_id:1
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

let test_malformed_output_has_utf8_snapshot_and_live_tail () =
  let raw = "plain 한글 🧭\n\255 partial \237\149" in
  let displayed = "plain 한글 🧭\n� partial �" in
  EO.record_completed ~keeper_name:"alpha" ~task_id:None
    ~stdout:raw ~stderr:raw ~status:status_ok ();
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json ~keeper_name:"alpha" in
  check bool "snapshot frame is UTF-8" true
    (String_util.is_valid_utf8 (EO.sse_frame snapshot));
  List.iter (fun field ->
    check string field displayed (snapshot |> member field |> to_string))
    ["stdout_since"; "stderr_since"];
  (match EO.snapshot ~keeper_name:"alpha" with
   | None -> fail "expected raw snapshot"
   | Some retained ->
     check string "raw stdout preserved" raw retained.stdout_since;
     check string "raw stderr preserved" raw retained.stderr_since;
     check int "stdout byte count" (String.length raw) retained.since_stdout;
     check int "stderr byte count" (String.length raw) retained.since_stderr);
  Eio_main.run (fun env ->
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect ~finally:(fun () -> EO.unsubscribe subscriber) (fun () ->
        EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stdout raw;
        EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stderr raw;
        let events = take_events env subscriber ~count:4 in
        List.iter (fun event ->
          check bool "live frame is UTF-8" true
            (String_util.is_valid_utf8 (EO.sse_frame event))) events;
        check (list string) "valid text survives; malformed sequences are replaced"
          ["plain 한글 🧭"; "� partial �"; "plain 한글 🧭"; "� partial �"]
          (List.map line_text events)))

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
           EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "task-big");
           EO.append_stream_chunk ~stream_id:1
             ~keeper_name:"alpha"
             ~stream:`Stdout
             (numbered_lines ~count:row_count);
           EO.record_stream_end ~stream_id:1
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
           EO.append_stream_chunk ~stream_id:1
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
             [ 1; 2 ]
             (initial |> member "lines" |> to_list
              |> List.map (fun line -> line |> member "seq" |> to_int));
           EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stdout "after snapshot\n";
           let next =
             Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
               EO.take_event subscriber |> EO.stream_event_json)
           in
           check string "next is new line" "after snapshot" (line_text next);
           check int "next number" 3 (json_seq next)))

(* A viewer opening an already-running first Execute must see its retained
   output and open state, then continue after the snapshot without replay. *)
let test_subscribe_during_first_execution () =
  Eio_main.run (fun env ->
    EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "task-live");
    EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stdout "already running\n";
    match EO.subscribe ~keeper_name:"alpha" with
    | None -> fail "expected subscriber"
    | Some subscriber ->
      Fun.protect ~finally:(fun () -> EO.unsubscribe subscriber) (fun () ->
        let initial = EO.initial_event_json subscriber in
        let open Yojson.Safe.Util in
        check string "snapshot" "snapshot" (json_type initial);
        check bool "running" false (initial |> member "closed" |> to_bool);
        check string "active task" "task-live" (initial |> member "task_id" |> to_string);
        check (list string) "retained output" [ "already running" ]
          (initial |> member "lines" |> to_list
           |> List.map (fun line -> line |> member "text" |> to_string));
        EO.append_stream_chunk ~stream_id:1 ~keeper_name:"alpha" ~stream:`Stderr "later\n";
        let next =
          Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 1.0 (fun () ->
            EO.take_event subscriber |> EO.stream_event_json)
        in
        check string "new output" "later" (line_text next);
        check int "next sequence" 3 (json_seq next)))

let test_current_stream_supersedes_prior_completion () =
  EO.inject_for_testing ~keeper_name:"alpha" ~task_id:"old"
    ~stdout:"old output\n" ~stderr:"" ~status:status_ok ();
  EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "new");
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json ~keeper_name:"alpha" in
  check bool "current stream is open" false (snapshot |> member "closed" |> to_bool);
  check string "current task" "new" (snapshot |> member "task_id" |> to_string);
  check bool "prior status is not current" true (snapshot |> member "status" = `Null)

let test_closed_stream_without_completed_capture () =
  EO.record_stream_start ~stream_id:1 ~command:"" ~keeper_name:"alpha" ~task_id:(Some "failed");
  EO.record_stream_end ~stream_id:1 ~keeper_name:"alpha" ~task_id:(Some "failed")
    ~status:(`Assoc [ "rejected", `String "path_reject" ]);
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json ~keeper_name:"alpha" in
  check string "snapshot exists" "snapshot" (json_type snapshot);
  check bool "closed" true (snapshot |> member "closed" |> to_bool);
  check string "actual terminal status" "path_reject"
    (snapshot |> member "status" |> member "rejected" |> to_string)

let test_snapshot_preserves_earlier_unknown_close () =
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:11 ~task_id:(Some "a") ~command:"a";
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:12 ~task_id:(Some "b") ~command:"b";
  EO.record_stream_end ~keeper_name:"alpha" ~stream_id:11 ~task_id:(Some "a")
    ~status:(`Assoc [ "outcome", `String "unknown" ]);
  EO.record_stream_end ~keeper_name:"alpha" ~stream_id:12 ~task_id:(Some "b") ~status:status_ok;
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json ~keeper_name:"alpha" in
  let lines = snapshot |> member "lines" |> to_list in
  let first_close = List.find (fun line ->
    (line |> member "stream") = `String "status"
    && (line |> member "stream_id") = `Int 11) lines in
  let status = first_close |> member "text" |> to_string |> Yojson.Safe.from_string in
  check string "the earlier stream still reports its unknown effect" "unknown"
    (status |> member "outcome" |> to_string);
  check string "the later stream remains the latest status" "exit"
    (snapshot |> member "status" |> member "kind" |> to_string)

let test_overlapping_streams_keep_identity_and_open_state () =
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:11 ~task_id:(Some "a") ~command:"echo a";
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:12 ~task_id:(Some "b") ~command:"echo b";
  EO.append_stream_chunk ~keeper_name:"alpha" ~stream_id:11 ~stream:`Stdout "output a\n";
  EO.append_stream_chunk ~keeper_name:"alpha" ~stream_id:12 ~stream:`Stderr "output b\n";
  EO.record_stream_end ~keeper_name:"alpha" ~stream_id:11 ~task_id:(Some "a") ~status:status_ok;
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json ~keeper_name:"alpha" in
  check bool "second stream is still active" false (snapshot |> member "closed" |> to_bool);
  check int "one stream remains" 1 (snapshot |> member "active_count" |> to_int);
  check string "remaining task" "b" (snapshot |> member "task_id" |> to_string);
  let lines = snapshot |> member "lines" |> to_list in
  let find_text wanted = List.find (fun line -> line |> member "text" |> to_string = wanted) lines in
  List.iter (fun (text, id, task) ->
    let line = find_text text in
    check int (text ^ " stream") id (line |> member "stream_id" |> to_int);
    check string (text ^ " task") task (line |> member "task_id" |> to_string))
    [ "echo a", 11, "a"; "echo b", 12, "b"; "output a", 11, "a"; "output b", 12, "b" ];
  EO.record_stream_end ~keeper_name:"alpha" ~stream_id:12 ~task_id:(Some "b") ~status:status_ok;
  check bool "closed only after both finish" true
    (EO.event_json ~keeper_name:"alpha" |> member "closed" |> to_bool)

let test_snapshot_discloses_evicted_live_history () =
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:1 ~task_id:None ~command:"";
  EO.append_stream_chunk ~keeper_name:"alpha" ~stream_id:1 ~stream:`Stdout
    (numbered_lines ~count:(EO.event_log_capacity + 10));
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json ~keeper_name:"alpha" in
  check bool "old events were evicted" true (snapshot |> member "first_retained_seq" |> to_int > 1);
  check int "completed byte counter does not pretend to count live evictions" 0
    (snapshot |> member "bytes_dropped_stdout" |> to_int)

let test_limited_snapshot_retains_active_command () =
  EO.record_stream_start ~keeper_name:"alpha" ~stream_id:8 ~task_id:(Some "task-a") ~command:"echo work";
  EO.append_stream_chunk ~keeper_name:"alpha" ~stream_id:8 ~stream:`Stdout
    (numbered_lines ~count:12);
  let open Yojson.Safe.Util in
  let snapshot = EO.event_json_limited ~keeper_name:"alpha" ~line_limit:4 in
  check int "only the requested rows travel" 4 (snapshot |> member "lines" |> to_list |> List.length);
  check int "older retained rows are disclosed" 9 (snapshot |> member "lines_omitted" |> to_int);
  check bool "full completed captures are not sent" true (snapshot |> member "stdout_since" = `Null);
  match snapshot |> member "active_streams" |> to_list with
  | [active] ->
    check string "active command survives the projection" "echo work"
      (active |> member "command" |> to_string)
  | _ -> fail "expected the active command"

let test_sse_frame () =
  let frame = EO.sse_frame (`Assoc [ "type", `String "snapshot" ]) in
  check bool "event header" true (String.starts_with ~prefix:"event: output\n" frame);
  check bool "data line" true (String.contains frame '{');
  check bool "terminator" true (String.ends_with ~suffix:"\n\n" frame)

(* Drive the actual HTTP/1 route without closing the response. The output
   driver acknowledges each write only when the test reads it, as a socket
   writer would. The later Closed result must release the stream fiber, so the
   surrounding Switch can finish. *)
let test_route_delivers_open_stream_and_releases_on_disconnect () =
  let previous_state = Server_auth.For_testing.snapshot_server_state () in
  let previous_startup = Masc.Server_startup_state.snapshot () in
  let base = Filename.temp_file "masc-execute-output-http-" "" in
  Unix.unlink base;
  Unix.mkdir base 0o700;
  Unix.mkdir (Filename.concat base ".masc") 0o700;
  let base = Unix.realpath base in
  let root = Unix.realpath (Filename.concat base ".masc") in
  let env_keys = [ "MASC_HTTP_AUTH_STRICT"; "MASC_HOST"; "MASC_HTTP_BASE_URL"; "MASC_BASE_PATH" ] in
  let previous_env = List.map (fun name -> name, Sys.getenv_opt name) env_keys in
  let restore_env (name, value) =
    match value with Some value -> Unix.putenv name value | None -> Unix.unsetenv name
  in
  Fun.protect
    ~finally:(fun () ->
      Server_auth.For_testing.restore_server_state previous_state;
      Masc.Server_startup_state.For_testing.restore previous_startup;
      List.iter restore_env previous_env;
      Masc_test_deps.cleanup_test_workspace base)
    (fun () ->
      Unix.putenv "MASC_HTTP_AUTH_STRICT" "false";
      Unix.putenv "MASC_HOST" "127.0.0.1";
      Unix.unsetenv "MASC_HTTP_BASE_URL";
      Server_auth.publish_server_state
        (Masc.Mcp_server.For_testing.create_state ~base_path:base);
      Masc.Server_startup_state.reset ();
      (match Masc.Server_startup_state.mark_state_ready () with
       | Ok () -> ()
       | Error error -> fail (Masc.Server_startup_state.state_ready_error_to_string error));
      Eio_main.run (fun env ->
        Eio.Time.with_timeout_exn (Eio.Stdenv.clock env) 5.0 (fun () ->
          Eio.Switch.run (fun sw ->
            let routes = Server_routes_http_routes_dashboard.add_routes
                ~sw ~clock:(Eio.Stdenv.clock env) (Router.create ()) in
            let authority = match Server_request_authority.of_host_port ~host:"127.0.0.1" ~port:8935 with
              | Ok authority -> authority
              | Error `Malformed -> fail "invalid test authority" in
            let dispatch reqd =
              Server_request_authority.with_current authority (fun () ->
                Router.dispatch routes (Httpun.Reqd.request reqd) reqd) in
            EO.inject_for_testing ~keeper_name:"alpha" ~task_id:"first"
              ~stdout:"before subscription\n" ~stderr:"" ~status:status_ok ();
            let connection = Httpun.Server_connection.create dispatch in
            let request = "GET /api/v1/dashboard/execute-output/alpha HTTP/1.1\r\nHost: localhost\r\n\r\n" in
            let input = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
            ignore (Httpun.Server_connection.read connection input ~off:0 ~len:(Bigstringaf.length input));
            let received = Buffer.create 1024 in
            let rec read_until text =
              if not (String_util.contains_substring (Buffer.contents received) text) then
                match Httpun.Server_connection.next_write_operation connection with
                | `Write iovecs ->
                  let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
                    Buffer.add_string received
                      (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                    count + iov.len) 0 iovecs in
                  Httpun.Server_connection.report_write_result connection (`Ok count);
                  read_until text
                | `Yield ->
                  let ready, resolve = Eio.Promise.create () in
                  Httpun.Server_connection.yield_writer connection (fun () -> Eio.Promise.resolve resolve ());
                  Eio.Promise.await ready;
                  read_until text
                | `Close _ -> fail "stream closed before sending output"
            in
            read_until "before subscription";
            check bool "initial response headers reached the client" true
              (String_util.contains_substring (Buffer.contents received) "HTTP/1.1 200");
            EO.inject_for_testing ~keeper_name:"alpha" ~task_id:"second"
              ~stdout:"after subscription\n" ~stderr:"" ~status:status_ok ();
            read_until "after subscription";
            (* Start one more write, then make the transport reject it while
               the producer is awaiting flush. *)
            EO.inject_for_testing ~keeper_name:"alpha" ~task_id:"third"
              ~stdout:"disconnect\n" ~stderr:"" ~status:status_ok ();
            let rec disconnect_when_writable () =
              match Httpun.Server_connection.next_write_operation connection with
              | `Write _ -> Httpun.Server_connection.report_write_result connection `Closed
              | `Yield ->
                let ready, resolve = Eio.Promise.create () in
                Httpun.Server_connection.yield_writer connection (fun () -> Eio.Promise.resolve resolve ());
                Eio.Promise.await ready;
                disconnect_when_writable ()
              | `Close _ -> fail "stream closed before the simulated disconnect"
            in
            disconnect_when_writable ();

            (* The browser may send an Origin on an EventSource GET. A
               rejected origin must not receive permission to read output,
               even when the loopback server allows unauthenticated reads. *)
            let stream_headers ?(target = "/api/v1/dashboard/execute-output/alpha") origin =
              let conn = Httpun.Server_connection.create dispatch in
              let request = Printf.sprintf
                  "GET %s HTTP/1.1\r\nHost: 127.0.0.1:8935\r\nOrigin: %s\r\n\r\n" target origin in
              let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
              ignore (Httpun.Server_connection.read conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
              let response = Buffer.create 512 in
              let rec read () =
                if String_util.contains_substring (Buffer.contents response) "\r\n\r\n" then
                  (Httpun.Server_connection.shutdown conn; Buffer.contents response)
                else match Httpun.Server_connection.next_write_operation conn with
                  | `Write iovecs ->
                    let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
                      Buffer.add_string response
                        (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                      count + iov.len) 0 iovecs in
                    Httpun.Server_connection.report_write_result conn (`Ok count);
                    read ()
                  | `Yield ->
                    let ready, resolve = Eio.Promise.create () in
                    Httpun.Server_connection.yield_writer conn (fun () -> Eio.Promise.resolve resolve ());
                    Eio.Promise.await ready;
                    read ()
                  | `Close _ -> fail "stream closed before response headers" in
              read () in
            let evil = String.lowercase_ascii (stream_headers "https://evil.example") in
            check bool "cross-origin stream does not grant browser read access" false
              (String_util.contains_substring evil "access-control-allow-origin:");
            let same = String.lowercase_ascii (stream_headers "http://127.0.0.1:8935") in
            check bool "same-origin stream is allowed" true
              (String_util.contains_substring same
                 "access-control-allow-origin: http://127.0.0.1:8935");
            let encode = Uri.pct_encode ~component:`Query_value in
            let stream_path = "/api/v1/dashboard/execute-output/alpha" in
            let matching_stream = stream_headers ~target:(stream_path ^ "?expected_base_path=" ^
                encode base ^ "&expected_masc_root=" ^ encode root) "http://127.0.0.1:8935"
              |> String.lowercase_ascii in
            check bool "matching stream reports workspace admission" true
              (String_util.contains_substring matching_stream "x-masc-workspace-read: matched-v1");
            let wrong_stream = stream_headers ~target:(stream_path ^ "?expected_base_path=" ^
                encode (base ^ "-other") ^ "&expected_masc_root=" ^ encode root) "http://127.0.0.1:8935" in
            check bool "mismatched stream is refused" true
              (String_util.contains_substring wrong_stream " 409 ");
            check bool "mismatched stream does not reveal output" false
              (String_util.contains_substring wrong_stream "before subscription");

            (* The snapshot is the same retained observation and is bound to
               the requesting workspace by the ordinary read precondition. *)
            let snapshot_path = "/api/v1/dashboard/execute-output-snapshot/alpha" in
            let wire_response ?origin target =
              let response = Buffer.create 1024 in
              let conn = Httpun.Server_connection.create dispatch in
              let origin = match origin with None -> "" | Some origin -> "Origin: " ^ origin ^ "\r\n" in
              let request = Printf.sprintf "GET %s HTTP/1.0\r\nHost: 127.0.0.1:8935\r\n%s\r\n" target origin in
              let bytes = Bigstringaf.of_string ~off:0 ~len:(String.length request) request in
              ignore (Httpun.Server_connection.read_eof conn bytes ~off:0 ~len:(Bigstringaf.length bytes));
              let rec drain () = match Httpun.Server_connection.next_write_operation conn with
                | `Write iovecs ->
                  let count = List.fold_left (fun count (iov : Bigstringaf.t Httpun.IOVec.t) ->
                    Buffer.add_string response
                      (Bigstringaf.substring iov.buffer ~off:iov.off ~len:iov.len);
                    count + iov.len) 0 iovecs in
                  Httpun.Server_connection.report_write_result conn (`Ok count);
                  drain ()
                | `Yield ->
                  let ready, resolve = Eio.Promise.create () in
                  Httpun.Server_connection.yield_writer conn (fun () -> Eio.Promise.resolve resolve ());
                  Eio.Promise.await ready;
                  drain ()
                | `Close _ -> Buffer.contents response in
              drain ()
            in
            let query = "?expected_base_path=" ^ encode base ^ "&expected_masc_root=" ^ encode root in
            let status response = match String.split_on_char ' ' response with
              | _version :: code :: _ -> int_of_string code
              | _ -> fail "malformed HTTP status" in
            let matched = wire_response (snapshot_path ^ query) in
            check int "snapshot request succeeds" 200 (status matched);
            check bool "matched workspace is acknowledged" true
              (String_util.contains_substring (String.lowercase_ascii matched)
                 "x-masc-workspace-read: matched-v1");
            check bool "snapshot contains retained output" true
              (String_util.contains_substring matched "after subscription");
            let snapshot_cross = String.lowercase_ascii (wire_response ~origin:"https://evil.example" snapshot_path) in
            check bool "cross-origin snapshot does not grant browser read access" false
              (String_util.contains_substring snapshot_cross "access-control-allow-origin:");
            let snapshot_same = String.lowercase_ascii (wire_response ~origin:"http://127.0.0.1:8935" snapshot_path) in
            check bool "same-origin snapshot is allowed" true
              (String_util.contains_substring snapshot_same
                 "access-control-allow-origin: http://127.0.0.1:8935");
            let limited = wire_response (snapshot_path ^ "?limit=1&expected_base_path=" ^
              encode base ^ "&expected_masc_root=" ^ encode root) in
            check int "limited snapshot succeeds" 200 (status limited);
            check bool "projection names omitted retained rows" true
              (String_util.contains_substring limited "\"lines_omitted\":5");
            let invalid_limit = wire_response (snapshot_path ^ "?limit=0") in
            check int "invalid row limit is refused" 400 (status invalid_limit);
            let wrong = wire_response (snapshot_path ^ "?expected_base_path=" ^
              encode (base ^ "-other") ^ "&expected_masc_root=" ^ encode root) in
            check int "wrong workspace is refused" 409 (status wrong);
            check bool "wrong workspace does not leak output" false
              (String_util.contains_substring wrong "after subscription");
            let blank = wire_response "/api/v1/dashboard/execute-output-snapshot/%20" in
            check int "blank keeper name is refused" 400 (status blank)))))

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
        "/api/v1/dashboard/execute-output/";
      check_route
        "snapshot route"
        "/api/v1/dashboard/execute-output-snapshot/alpha"
        "/api/v1/dashboard/execute-output-snapshot/"))

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
        ; test_case "malformed output has UTF-8 snapshot and live tail"
            `Quick (with_fresh test_malformed_output_has_utf8_snapshot_and_live_tail)
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
        ; test_case "subscribe during first execution" `Quick
            (with_fresh test_subscribe_during_first_execution)
        ; test_case "current stream supersedes prior completion" `Quick
            (with_fresh test_current_stream_supersedes_prior_completion)
        ; test_case "closed stream without completed capture" `Quick
            (with_fresh test_closed_stream_without_completed_capture)
        ; test_case "snapshot retains earlier unknown close" `Quick
            (with_fresh test_snapshot_preserves_earlier_unknown_close)
        ; test_case "overlapping streams retain identities" `Quick
            (with_fresh test_overlapping_streams_keep_identity_and_open_state)
        ; test_case "snapshot discloses evicted live history" `Quick
            (with_fresh test_snapshot_discloses_evicted_live_history)
        ; test_case "limited snapshot keeps the active command" `Quick
            (with_fresh test_limited_snapshot_retains_active_command)
        ; test_case "sse frame" `Quick test_sse_frame
        ; test_case "HTTP stream delivers while open and stops on disconnect" `Quick
            (with_fresh test_route_delivers_open_stream_and_releases_on_disconnect)
        ; test_case "routes match keeper path" `Quick test_dashboard_routes_match_keeper_path
        ] )
    ]
