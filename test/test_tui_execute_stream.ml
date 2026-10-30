(* What the Terminal tab holds when it follows a Keeper's Execute output over
   the stream, read from the bytes the server really writes.

   The frames here are made by the server's own module
   ([Dashboard_execute_output]), in the order and the form the route sends
   them: a [retry:] line, the first frame, then one frame per event. A reader
   that drifted from the server would pass tests built on frames written by
   hand. The question these tests ask again and again is the one a viewer
   cares about: after the stream, does the reader hold what a fresh snapshot
   would show? *)

module EO = Dashboard_execute_output
module S = Masc_tui_execute_stream

let keeper = "alpha"
let exit_status code = `Assoc [ "kind", `String "exit"; "code", `Int code ]
let reset () = EO.reset_for_testing ()

let triple_of_line (line : S.line) = line.seq, line.stream, line.text
let triple_of_output (line : EO.output_line) = line.seq, line.stream, line.text
let rows = Alcotest.(list (triple int string string))

(* The server sends [no_task] until a Keeper's log holds a command's start or
   end, so a test that wants a snapshot opens a stream first: one [task_opened]
   (number 1) and one row for the command (number 2). *)
let open_stream ?(stream_id = 1) () =
  EO.record_stream_start ~keeper_name:keeper ~stream_id ~task_id:None ~command:"run"
;;

let run_command ~stream_id ~command ~stdout ~stderr ~status =
  EO.record_stream_start
    ~keeper_name:keeper
    ~stream_id
    ~task_id:(Some (Printf.sprintf "task-%d" stream_id))
    ~command;
  if stdout <> ""
  then EO.append_stream_chunk ~keeper_name:keeper ~stream_id ~stream:`Stdout stdout;
  if stderr <> ""
  then EO.append_stream_chunk ~keeper_name:keeper ~stream_id ~stream:`Stderr stderr;
  EO.record_stream_end
    ~keeper_name:keeper
    ~stream_id
    ~task_id:(Some (Printf.sprintf "task-%d" stream_id))
    ~status
;;

(* One connection as the route writes it. [produce] runs after the
   subscription, so what it logs reaches the reader as events; [events] is how
   many of them to take. *)
let connection env ~events ~produce =
  match EO.subscribe ~keeper_name:keeper with
  | None -> Alcotest.fail "the server gave no subscriber"
  | Some subscriber ->
    Fun.protect
      ~finally:(fun () -> EO.unsubscribe subscriber)
      (fun () ->
         let first = EO.sse_frame (EO.initial_event_json subscriber) in
         produce ();
         let clock = Eio.Stdenv.clock env in
         let frames =
           List.init events (fun _ ->
             Eio.Time.with_timeout_exn clock 1.0 (fun () ->
               EO.sse_frame (EO.stream_event_json (EO.take_event subscriber))))
         in
         "retry: 1500\n\n" ^ first, frames)
;;

let feed reader ?(now = 1000.0) text =
  match S.feed reader ~now text with
  | S.Keep_reading -> ()
  | S.Reconnect failure ->
    Alcotest.failf "the reader asked for a new connection: %s" (S.failure_to_string failure)
;;

let reconnect_reason reader ?(now = 1000.0) text =
  match S.feed reader ~now text with
  | S.Keep_reading -> Alcotest.fail "the reader took what it should have refused"
  | S.Reconnect failure -> failure
;;

let new_reader ?(capacity = 500) () =
  let reader = S.create ~keeper ~capacity in
  S.started reader;
  reader
;;

let observed reader =
  match S.view reader with
  | S.Observed reading -> reading
  | S.Awaiting_first_frame -> Alcotest.fail "the reader has told nothing yet"
  | S.Nothing_observed -> Alcotest.fail "the reader says nothing was observed"
;;

let server_rows () =
  match EO.snapshot ~keeper_name:keeper with
  | None -> Alcotest.fail "the server holds no output"
  | Some snapshot -> List.map triple_of_output snapshot.lines
;;

let reader_rows reader = List.map triple_of_line (observed reader).lines
let texts (lines : S.line list) = List.map (fun (line : S.line) -> line.text) lines

let with_server test () =
  reset ();
  Eio_main.run (fun env -> test env)
;;

let test_a_followed_stream_ends_with_the_rows_a_fresh_snapshot_holds env =
  run_command
    ~stream_id:1
    ~command:"make all"
    ~stdout:"compiling a\ncompiling b\n"
    ~stderr:"warning: x\n"
    ~status:(exit_status 0);
  (* opened, one command row, one stdout row, one close. *)
  let head, events =
    connection env ~events:4 ~produce:(fun () ->
      run_command ~stream_id:2 ~command:"echo hi" ~stdout:"hi\n" ~stderr:"" ~status:(exit_status 2))
  in
  let reader = new_reader () in
  feed reader head;
  List.iter (feed reader) events;
  Alcotest.check rows "the rows, closes included" (server_rows ()) (reader_rows reader);
  let reading = observed reader in
  Alcotest.(check int) "no command runs" 0 reading.active_count;
  Alcotest.(check bool) "the output is closed" true reading.closed;
  Alcotest.(check int) "nothing was pushed out" 0 reading.lines_omitted
;;

let test_a_close_too_long_for_a_row_reads_as_the_server_shows_it env =
  let long_status = `Assoc [ "reason", `String (String.make 5000 'x') ] in
  EO.record_stream_start ~keeper_name:keeper ~stream_id:1 ~task_id:None ~command:"first";
  let head, events =
    connection env ~events:1 ~produce:(fun () ->
      EO.record_stream_end ~keeper_name:keeper ~stream_id:1 ~task_id:None ~status:long_status)
  in
  let reader = new_reader () in
  feed reader head;
  List.iter (feed reader) events;
  Alcotest.check rows "the close row" (server_rows ()) (reader_rows reader)
;;

let test_the_reader_keeps_the_newest_rows_and_counts_the_rest env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "1\n2\n3\n4\n5\n";
  let head, events =
    connection env ~events:2 ~produce:(fun () ->
      EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "6\n7\n")
  in
  let reader = new_reader ~capacity:3 () in
  feed reader head;
  Alcotest.(check (list string))
    "the snapshot's newest rows"
    [ "3"; "4"; "5" ]
    (texts (observed reader).lines);
  Alcotest.(check int) "the command row and two rows did not fit" 3 (observed reader).lines_omitted;
  List.iter (feed reader) events;
  let reading = observed reader in
  Alcotest.(check (list string))
    "the newest rows after more arrive"
    [ "5"; "6"; "7" ]
    (texts reading.lines);
  Alcotest.(check int) "five rows are not in the reading" 5 reading.lines_omitted
;;

(* A row is pushed out only when the reader would hold more than its capacity.
   The test above starts from a snapshot that already fills it; this one fills
   it a row at a time and then adds one more. *)
let test_the_reader_holds_its_capacity_before_it_pushes_a_row_out env =
  open_stream ();
  let head, events =
    connection env ~events:3 ~produce:(fun () ->
      EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "a\nb\nc\n")
  in
  let reader = new_reader ~capacity:3 () in
  feed reader head;
  match events with
  | [ first; second; third ] ->
    feed reader first;
    feed reader second;
    let full = observed reader in
    Alcotest.(check (list string))
      "the command row and two rows fill it"
      [ "run"; "a"; "b" ]
      (texts full.lines);
    Alcotest.(check int) "and none was pushed out" 0 full.lines_omitted;
    feed reader third;
    let over = observed reader in
    Alcotest.(check (list string))
      "one more pushes the oldest out"
      [ "a"; "b"; "c" ]
      (texts over.lines);
    Alcotest.(check int) "and it is counted" 1 over.lines_omitted
  | other -> Alcotest.failf "expected three frames, got %d" (List.length other)
;;

let test_a_command_that_runs_when_the_snapshot_is_taken_keeps_its_command env =
  EO.record_stream_start ~keeper_name:keeper ~stream_id:7 ~task_id:(Some "build") ~command:"sleep 30";
  let head, _ = connection env ~events:0 ~produce:ignore in
  let reader = new_reader () in
  feed reader head;
  let reading = observed reader in
  Alcotest.(check int) "one command runs" 1 reading.active_count;
  Alcotest.(check bool) "so the output is not closed" false reading.closed;
  match reading.active with
  | [ active ] ->
    Alcotest.(check int) "its stream" 7 active.id;
    Alcotest.(check string) "its command, as the server holds it" "sleep 30" active.command
  | other -> Alcotest.failf "expected one running command, got %d" (List.length other)
;;

let test_a_command_that_starts_after_the_snapshot_is_named_by_its_first_row env =
  run_command ~stream_id:1 ~command:"true" ~stdout:"" ~stderr:"" ~status:(exit_status 0);
  let head, events =
    connection env ~events:4 ~produce:(fun () ->
      EO.record_stream_start
        ~keeper_name:keeper
        ~stream_id:3
        ~task_id:None
        ~command:"make\n  all";
      EO.record_stream_end ~keeper_name:keeper ~stream_id:3 ~task_id:None ~status:(exit_status 0))
  in
  let reader = new_reader () in
  feed reader head;
  (match events with
   | [ opened; first_row; second_row; closed ] ->
     feed reader opened;
     let reading = observed reader in
     Alcotest.(check int) "the command counts as running" 1 reading.active_count;
     Alcotest.(check int) "but has no name yet, so it is not listed" 0 (List.length reading.active);
     feed reader first_row;
     (match (observed reader).active with
      | [ active ] ->
        Alcotest.(check string) "named by its first row" "make" active.command
      | other -> Alcotest.failf "expected one running command, got %d" (List.length other));
     feed reader second_row;
     (match (observed reader).active with
      | [ active ] ->
        Alcotest.(check string) "a later row does not rename it" "make" active.command
      | other -> Alcotest.failf "expected one running command, got %d" (List.length other));
     feed reader closed;
     let reading = observed reader in
     Alcotest.(check int) "it ended" 0 reading.active_count;
     Alcotest.(check int) "and is no longer listed" 0 (List.length reading.active);
     Alcotest.(check bool) "the output is closed" true reading.closed
   | other -> Alcotest.failf "expected four frames, got %d" (List.length other))
;;

let test_nothing_observed_then_the_first_command env =
  let head, events =
    connection env ~events:3 ~produce:(fun () ->
      run_command ~stream_id:1 ~command:"ls" ~stdout:"" ~stderr:"" ~status:(exit_status 0))
  in
  let reader = new_reader () in
  feed reader head;
  Alcotest.(check bool)
    "a Keeper with no Execute output reads as that"
    true
    (S.view reader = S.Nothing_observed);
  (* opened, the command row, the close. *)
  List.iter (feed reader) events;
  Alcotest.check rows "the command, then how it ended" (server_rows ()) (reader_rows reader);
  Alcotest.(check bool) "closed" true (observed reader).closed
;;

let test_events_that_skip_a_number_ask_for_a_new_connection env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "before\n";
  let head, events =
    connection env ~events:3 ~produce:(fun () ->
      EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "a\nb\nc\n")
  in
  let reader = new_reader () in
  feed reader head;
  (match events with
   | [ _lost; second; _third ] ->
     (match reconnect_reason reader second with
      | S.Out_of_order { expected; received } ->
        Alcotest.(check int) "it wanted the next number" 4 expected;
        Alcotest.(check int) "it got the one after" 5 received
      | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other))
   | other -> Alcotest.failf "expected three frames, got %d" (List.length other))
;;

let test_a_gap_the_server_names_asks_for_a_new_connection env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "first\n";
  let burst = String.concat "" (List.init (EO.event_log_capacity + 10) (fun i -> Printf.sprintf "row %d\n" i)) in
  let head, events =
    connection env ~events:1 ~produce:(fun () ->
      EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout burst)
  in
  let reader = new_reader () in
  feed reader head;
  match events with
  | [ gap ] ->
    (match reconnect_reason reader gap with
     | S.Events_lost { from_seq; to_seq } ->
       Alcotest.(check bool) "it names numbers the server no longer has" true (from_seq <= to_seq)
     | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other))
  | other -> Alcotest.failf "expected one frame, got %d" (List.length other)
;;

let test_an_event_before_the_snapshot_is_refused env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "before\n";
  let _, events =
    connection env ~events:1 ~produce:(fun () ->
      EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "after\n")
  in
  let reader = new_reader () in
  match events with
  | [ event ] ->
    (match reconnect_reason reader event with
     | S.Frame_rejected _ -> ()
     | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other))
  | other -> Alcotest.failf "expected one frame, got %d" (List.length other)
;;

let test_a_frame_for_another_keeper_is_refused env =
  EO.record_stream_start ~keeper_name:"beta" ~stream_id:1 ~task_id:None ~command:"not yours";
  let head =
    match EO.subscribe ~keeper_name:"beta" with
    | None -> Alcotest.fail "the server gave no subscriber"
    | Some subscriber ->
      Fun.protect
        ~finally:(fun () -> EO.unsubscribe subscriber)
        (fun () -> EO.sse_frame (EO.initial_event_json subscriber))
  in
  ignore env;
  let reader = new_reader () in
  match reconnect_reason reader head with
  | S.Another_keeper { expected; received } ->
    Alcotest.(check string) "it expected this Keeper" keeper expected;
    Alcotest.(check string) "and was told about the other" "beta" received
  | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other)
;;

let test_the_chunking_of_the_bytes_does_not_matter env =
  run_command ~stream_id:1 ~command:"a" ~stdout:"x\ny\n" ~stderr:"" ~status:(exit_status 0);
  let head, events =
    connection env ~events:3 ~produce:(fun () ->
      run_command ~stream_id:2 ~command:"b" ~stdout:"" ~stderr:"" ~status:(exit_status 1))
  in
  let whole = new_reader () in
  feed whole (String.concat "" (head :: events));
  let by_byte = new_reader () in
  String.iter (fun c -> feed by_byte (String.make 1 c)) (String.concat "" (head :: events));
  Alcotest.check rows "the same rows" (reader_rows whole) (reader_rows by_byte);
  Alcotest.check rows "and they are the server's" (server_rows ()) (reader_rows whole)
;;

let test_a_new_connection_replaces_the_rows_at_its_snapshot env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "old\n";
  let first_head, _ = connection env ~events:0 ~produce:ignore in
  let reader = new_reader () in
  feed reader first_head;
  let old_rows = reader_rows reader in
  S.started reader;
  Alcotest.check rows "what was held stays until the snapshot" old_rows (reader_rows reader);
  (* The server restarts and numbers from 1 again. *)
  reset ();
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "new\n";
  let second_head, second_events =
    connection env ~events:1 ~produce:(fun () ->
      EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "newer\n")
  in
  (match second_events with
   | [ event ] ->
     (match reconnect_reason reader event with
      | S.Frame_rejected _ -> ()
      | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other))
   | other -> Alcotest.failf "expected one frame, got %d" (List.length other));
  S.started reader;
  feed reader second_head;
  List.iter (feed reader) second_events;
  Alcotest.(check (list string))
    "only the new connection's rows"
    [ "run"; "new"; "newer" ]
    (texts (observed reader).lines)
;;

let test_a_keepalive_moves_the_time_and_not_the_rows env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "row\n";
  let head, _ = connection env ~events:0 ~produce:ignore in
  let reader = new_reader () in
  feed reader ~now:1000.0 head;
  let held = reader_rows reader in
  let version = S.version reader in
  feed reader ~now:1015.0 ": heartbeat\n\n";
  Alcotest.(check (float 0.0)) "the time of the last word" 1015.0 (observed reader).observed_at;
  Alcotest.check rows "the rows" held (reader_rows reader);
  Alcotest.(check bool) "the view may have changed" true (S.version reader > version)
;;

let test_the_version_moves_only_when_the_view_may_have_changed env =
  open_stream ();
  EO.append_stream_chunk ~keeper_name:keeper ~stream_id:1 ~stream:`Stdout "row\n";
  let head, _ = connection env ~events:0 ~produce:ignore in
  let reader = new_reader () in
  let start = S.version reader in
  feed reader "retry: 1500\n\n";
  Alcotest.(check int) "a retry line before the snapshot" start (S.version reader);
  feed reader (String.sub head 13 10);
  Alcotest.(check int) "half a frame" start (S.version reader);
  feed reader (String.sub head 23 (String.length head - 23));
  Alcotest.(check bool) "the snapshot" true (S.version reader > start);
  Alcotest.(check bool) "now a reading" true
    (match S.view reader with S.Observed _ -> true | S.Awaiting_first_frame | S.Nothing_observed -> false)
;;

(* Frames the server never sends, written by hand: what the reader does with
   them is the question, so they cannot come from the server's own module.
   The defaults are a valid snapshot of a log whose last number is 2. *)
let sse_data json = "data: " ^ json ^ "\n\n"

let snapshot_frame
      ?(first_retained = 1)
      ?(last = 2)
      ?(row_seqs = [ 2 ])
      ?(status = Some "null")
      ()
  =
  let row seq =
    Printf.sprintf
      {|{"seq":%d,"stream_id":1,"task_id":null,"stream":"stdout","text":"x","ansi":false,"ts_ms":0}|}
      seq
  in
  sse_data
    (Printf.sprintf
       {|{"type":"snapshot","keeper":"alpha","lines":[%s],"active_streams":[],"active_count":0,"first_retained_seq":%d,"last_seq":%d,"closed":true%s}|}
       (String.concat "," (List.map row row_seqs))
       first_retained
       last
       (match status with
        | Some value -> {|,"status":|} ^ value
        | None -> ""))
;;

let refused_for reader frame =
  match reconnect_reason reader frame with
  | S.Frame_rejected detail -> detail
  | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other)
;;

let test_a_snapshot_or_a_close_without_a_status_is_refused _env =
  let says_status detail = String_util.contains_substring detail "status" in
  Alcotest.(check bool)
    "a snapshot"
    true
    (says_status (refused_for (new_reader ()) (snapshot_frame ~status:None ())));
  let reader = new_reader () in
  feed reader (snapshot_frame ());
  let close =
    sse_data
      {|{"type":"task_closed","keeper":"alpha","seq":3,"stream_id":1,"task_id":null,"closed":true,"active_count":0}|}
  in
  Alcotest.(check bool) "a close" true (says_status (refused_for reader close));
  (* [null] is the server's way to say no command has ended; it is a status. *)
  feed (new_reader ()) (snapshot_frame ~status:(Some "null") ())
;;

let test_a_second_snapshot_on_one_connection_is_refused _env =
  let reader = new_reader () in
  feed reader (snapshot_frame ());
  ignore (refused_for reader (snapshot_frame ()) : string);
  (* The next connection starts again with its own snapshot. *)
  S.started reader;
  feed reader (snapshot_frame ());
  let no_task = sse_data {|{"type":"no_task","keeper":"alpha"}|} in
  let reader = new_reader () in
  feed reader no_task;
  ignore (refused_for reader no_task : string);
  let reader = new_reader () in
  feed reader (snapshot_frame ());
  ignore (refused_for reader no_task : string)
;;

let test_a_snapshot_whose_numbers_do_not_fit_is_refused _env =
  let refused label frame =
    let reader = new_reader () in
    ignore (refused_for reader frame : string);
    Alcotest.(check bool) (label ^ ": nothing was taken") true
      (S.view reader = S.Awaiting_first_frame)
  in
  refused "a row past the last number" (snapshot_frame ~row_seqs:[ 9 ] ());
  refused "a row before the oldest kept" (snapshot_frame ~first_retained:3 ~last:5 ~row_seqs:[ 2 ] ());
  refused "an oldest number past the last" (snapshot_frame ~first_retained:5 ~last:2 ~row_seqs:[] ());
  (* One past the last number is how an empty log looks. *)
  feed (new_reader ()) (snapshot_frame ~first_retained:3 ~last:2 ~row_seqs:[] ());
  feed (new_reader ()) (snapshot_frame ~first_retained:3 ~last:5 ~row_seqs:[ 3; 5 ] ())
;;

(* The question this file asks, put to a log long enough for the server's ring
   to have wrapped: after following it, does the reader hold what a reader that
   connects now is told? *)
let test_a_followed_stream_matches_a_fresh_snapshot_after_the_ring_wraps env =
  open_stream ();
  let capacity = 500 in
  let batch = 100 in
  let rounds = (EO.event_log_capacity / batch) + 3 in
  let clock = Eio.Stdenv.clock env in
  let followed = new_reader ~capacity () in
  (match EO.subscribe ~keeper_name:keeper with
   | None -> Alcotest.fail "the server gave no subscriber"
   | Some subscriber ->
     Fun.protect
       ~finally:(fun () -> EO.unsubscribe subscriber)
       (fun () ->
          feed followed ("retry: 1500\n\n" ^ EO.sse_frame (EO.initial_event_json subscriber));
          for round = 0 to rounds - 1 do
            let rows =
              List.init batch (fun index -> Printf.sprintf "row %d\n" ((round * batch) + index))
            in
            EO.append_stream_chunk
              ~keeper_name:keeper
              ~stream_id:1
              ~stream:`Stdout
              (String.concat "" rows);
            for _ = 1 to batch do
              feed
                followed
                (Eio.Time.with_timeout_exn clock 1.0 (fun () ->
                   EO.sse_frame (EO.stream_event_json (EO.take_event subscriber))))
            done
          done));
  let fresh = new_reader ~capacity () in
  let fresh_head, _ = connection env ~events:0 ~produce:ignore in
  feed fresh fresh_head;
  let held = observed followed
  and expected = observed fresh in
  Alcotest.(check bool) "the server's ring has wrapped" true (expected.first_seq > 1);
  Alcotest.(check int) "the oldest number the server keeps" expected.first_seq held.first_seq;
  Alcotest.(check int)
    "the rows the server keeps and the reader does not hold"
    expected.lines_omitted
    held.lines_omitted;
  Alcotest.check rows "the rows" (reader_rows fresh) (reader_rows followed)
;;

(* A log whose last 5,000 numbers hold few rows: the server's ring has dropped
   every row the reader still holds, and a new snapshot would list none. *)
let test_rows_the_servers_ring_has_dropped_are_not_held _env =
  let reader = new_reader ~capacity:3 () in
  feed reader (snapshot_frame ~first_retained:1 ~last:3 ~row_seqs:[ 2; 3 ] ());
  let opened seq =
    sse_data
      (Printf.sprintf
         {|{"type":"task_opened","keeper":"alpha","seq":%d,"stream_id":1,"task_id":null}|}
         seq)
  in
  feed
    reader
    (String.concat "" (List.init EO.event_log_capacity (fun index -> opened (4 + index))));
  let reading = observed reader in
  Alcotest.(check int) "the oldest number the server keeps" 4 reading.first_seq;
  Alcotest.(check (list string)) "no row is held" [] (texts reading.lines);
  Alcotest.(check int) "and none is left out" 0 reading.lines_omitted
;;

(* What one connection counted does not carry over to the next: a snapshot with
   fewer rows says how many the server keeps now, not how many the reader saw
   before. *)
let test_a_new_connections_snapshot_replaces_what_the_reader_counted _env =
  let reader = new_reader ~capacity:3 () in
  feed reader (snapshot_frame ~first_retained:1 ~last:6 ~row_seqs:[ 1; 2; 3; 4; 5; 6 ] ());
  Alcotest.(check int) "three of six rows did not fit" 3 (observed reader).lines_omitted;
  S.started reader;
  feed reader (snapshot_frame ());
  let reading = observed reader in
  Alcotest.(check (list string)) "only the new snapshot's row" [ "x" ] (texts reading.lines);
  Alcotest.(check int) "and nothing is left out" 0 reading.lines_omitted
;;

let test_a_frame_that_is_not_json_is_refused _env =
  let reader = new_reader () in
  match reconnect_reason reader "data: {not json\n\n" with
  | S.Frame_rejected _ -> ()
  | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other)
;;

let test_an_event_this_build_does_not_know_is_refused _env =
  let reader = new_reader () in
  match reconnect_reason reader ({|data: {"type":"hologram","keeper":"alpha"}|} ^ "\n\n") with
  | S.Frame_rejected detail ->
    Alcotest.(check bool) "it says which" true (String_util.contains_substring detail "hologram")
  | other -> Alcotest.failf "unexpected failure: %s" (S.failure_to_string other)
;;

let () =
  let case name test = Alcotest.test_case name `Quick (with_server test) in
  Alcotest.run
    "Tui_execute_stream"
    [ ( "following a stream"
      , [ case
            "a followed stream ends with the rows a fresh snapshot holds"
            test_a_followed_stream_ends_with_the_rows_a_fresh_snapshot_holds
        ; case
            "a close too long for a row reads as the server shows it"
            test_a_close_too_long_for_a_row_reads_as_the_server_shows_it
        ; case
            "the reader keeps the newest rows and counts the rest"
            test_the_reader_keeps_the_newest_rows_and_counts_the_rest
        ; case
            "the reader holds its capacity before it pushes a row out"
            test_the_reader_holds_its_capacity_before_it_pushes_a_row_out
        ; case
            "a command that runs at the snapshot keeps its command"
            test_a_command_that_runs_when_the_snapshot_is_taken_keeps_its_command
        ; case
            "a command that starts after the snapshot is named by its first row"
            test_a_command_that_starts_after_the_snapshot_is_named_by_its_first_row
        ; case
            "nothing observed, then the first command"
            test_nothing_observed_then_the_first_command
        ; case
            "the chunking of the bytes does not matter"
            test_the_chunking_of_the_bytes_does_not_matter
        ; case
            "a followed stream matches a fresh snapshot after the ring wraps"
            test_a_followed_stream_matches_a_fresh_snapshot_after_the_ring_wraps
        ; case
            "rows the server's ring has dropped are not held"
            test_rows_the_servers_ring_has_dropped_are_not_held
        ] )
    ; ( "losing the thread"
      , [ case
            "events that skip a number ask for a new connection"
            test_events_that_skip_a_number_ask_for_a_new_connection
        ; case
            "a gap the server names asks for a new connection"
            test_a_gap_the_server_names_asks_for_a_new_connection
        ; case
            "an event before the snapshot is refused"
            test_an_event_before_the_snapshot_is_refused
        ; case
            "a frame for another keeper is refused"
            test_a_frame_for_another_keeper_is_refused
        ; case
            "a frame that is not JSON is refused"
            test_a_frame_that_is_not_json_is_refused
        ; case
            "an event this build does not know is refused"
            test_an_event_this_build_does_not_know_is_refused
        ; case
            "a snapshot or a close without a status is refused"
            test_a_snapshot_or_a_close_without_a_status_is_refused
        ; case
            "a second snapshot on one connection is refused"
            test_a_second_snapshot_on_one_connection_is_refused
        ; case
            "a snapshot whose numbers do not fit is refused"
            test_a_snapshot_whose_numbers_do_not_fit_is_refused
        ] )
    ; ( "connections"
      , [ case
            "a new connection replaces the rows at its snapshot"
            test_a_new_connection_replaces_the_rows_at_its_snapshot
        ; case
            "a new connection's snapshot replaces what the reader counted"
            test_a_new_connections_snapshot_replaces_what_the_reader_counted
        ; case
            "a keepalive moves the time and not the rows"
            test_a_keepalive_moves_the_time_and_not_the_rows
        ; case
            "the version moves only when the view may have changed"
            test_the_version_moves_only_when_the_view_may_have_changed
        ] )
    ]
;;
