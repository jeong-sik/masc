(** The Candle ledger file (RFC-goal-candle-ledger 3.1): appended rows, a
    torn tail, a row that does not read, and a second writer getting in first. *)

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)

let snapshot ?(request_id = "req-1") goal_id : E.t =
  { at = at "2026-09-29T06:00:00Z"
  ; body =
      E.Snapshot
        { goal_id
        ; request_id
        ; criterion_revision = "rev-1"
        ; passed_at = at "2026-09-28T06:32:00Z"
        ; goal_created_at = at "2026-09-20T01:00:00Z"
        ; due_date = Some "2026-09-26"
        ; title = "Ship the ledger"
        ; metric = Some "tests"
        ; target_value = Some "10"
        ; linked_task_ids = [ "task-1"; "task-2" ]
        }
  }
;;

let goal_ids events =
  List.map
    (fun (event : E.t) ->
       match event.body with
       | E.Snapshot { goal_id; _ } -> goal_id)
    events
;;

let temp_dir () =
  let path = Filename.temp_file "candle_ledger_" "" in
  Sys.remove path;
  Unix.mkdir path 0o755;
  path
;;

let rec rm_rf path =
  if Sys.file_exists path
  then
    if Sys.is_directory path
    then (
      Array.iter (fun entry -> rm_rf (Filename.concat path entry)) (Sys.readdir path);
      Unix.rmdir path)
    else Sys.remove path
;;

let with_base_path f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect ~finally:(fun () -> rm_rf base_path) (fun () -> f base_path)
;;

let read_ok base_path =
  match Candle_ledger.read ~base_path with
  | Ok view -> view
  | Error error -> Alcotest.failf "%s" (Candle_ledger.read_error_to_string error)
;;

let update_ok base_path decide =
  match Candle_ledger.update ~base_path decide with
  | Ok value -> value
  | Error error ->
    Alcotest.failf "%s" (Candle_ledger.update_error_to_string Fun.id error)
;;

let file_text base_path = In_channel.with_open_bin (Candle_ledger.path ~base_path) In_channel.input_all

let append_raw base_path text =
  let path = Candle_ledger.path ~base_path in
  Fs_compat.mkdir_p_memoized (Filename.dirname path);
  Out_channel.with_open_gen [ Open_append; Open_creat; Open_binary ] 0o600 path (fun oc ->
    Out_channel.output_string oc text)
;;

let test_a_missing_file_is_an_empty_ledger () =
  with_base_path
  @@ fun base_path ->
  Alcotest.(check (list string)) "no events" [] (goal_ids (Candle_ledger.events (read_ok base_path)));
  Alcotest.(check bool)
    "reading does not create the file"
    false
    (Sys.file_exists (Candle_ledger.path ~base_path))
;;

let test_updates_append_rows_in_order () =
  with_base_path
  @@ fun base_path ->
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-a" ], ())) in
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-b"; snapshot "goal-c" ], ())) in
  Alcotest.(check (list string))
    "file order"
    [ "goal-a"; "goal-b"; "goal-c" ]
    (goal_ids (Candle_ledger.events (read_ok base_path)));
  let lines = String.split_on_char '\n' (file_text base_path) in
  Alcotest.(check int) "one line per event and a closing newline" 4 (List.length lines);
  Alcotest.(check string) "the file ends with a newline" "" (List.nth lines 3)
;;

let test_decide_sees_what_is_already_there () =
  with_base_path
  @@ fun base_path ->
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-a" ], ())) in
  let seen =
    update_ok base_path (fun view ->
      let seen = goal_ids (Candle_ledger.events view) in
      Ok ([ snapshot "goal-b" ], seen))
  in
  Alcotest.(check (list string)) "the view holds the first row" [ "goal-a" ] seen
;;

let test_no_events_writes_nothing () =
  with_base_path
  @@ fun base_path ->
  let () = update_ok base_path (fun _ -> Ok ([], ())) in
  Alcotest.(check bool)
    "no file"
    false
    (Sys.file_exists (Candle_ledger.path ~base_path))
;;

let test_a_refusal_writes_nothing () =
  with_base_path
  @@ fun base_path ->
  (match Candle_ledger.update ~base_path (fun _ -> Error "not now") with
   | Error (Candle_ledger.Refused "not now") -> ()
   | Error other ->
     Alcotest.failf "expected Refused, got %s" (Candle_ledger.update_error_to_string Fun.id other)
   | Ok () -> Alcotest.fail "a refusal was accepted");
  Alcotest.(check bool)
    "no file"
    false
    (Sys.file_exists (Candle_ledger.path ~base_path))
;;

(* The decide function of the first update appends a row through a second
   update before it answers, so the first update's read is out of date when it
   tries to append. It then reads again and decides again. *)
let test_a_writer_that_lost_the_race_reads_again () =
  with_base_path
  @@ fun base_path ->
  let calls = ref [] in
  let () =
    update_ok base_path (fun view ->
      calls := goal_ids (Candle_ledger.events view) :: !calls;
      if List.length !calls = 1
      then update_ok base_path (fun _ -> Ok ([ snapshot "interloper" ], ()));
      Ok ([ snapshot "mine" ], ()))
  in
  Alcotest.(check (list (list string)))
    "decide ran twice, and the second view held the interloper's row"
    [ [ "interloper" ]; [] ]
    !calls;
  Alcotest.(check (list string))
    "both rows are there, the interloper's first"
    [ "interloper"; "mine" ]
    (goal_ids (Candle_ledger.events (read_ok base_path)))
;;

let test_a_row_that_does_not_read_fails_the_read () =
  with_base_path
  @@ fun base_path ->
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-a" ], ())) in
  append_raw base_path "{\"kind\":\"not_a_kind\"}\n";
  (match Candle_ledger.read ~base_path with
   | Error (Candle_ledger.Row_rejected { line_number; _ }) ->
     Alcotest.(check int) "names the second line" 2 line_number
   | Error other ->
     Alcotest.failf "expected Row_rejected, got %s" (Candle_ledger.read_error_to_string other)
   | Ok _ -> Alcotest.fail "a bad row was skipped");
  let before = file_text base_path in
  (match Candle_ledger.update ~base_path (fun _ -> Ok ([ snapshot "goal-b" ], ())) with
   | Error (Candle_ledger.Read_failed (Candle_ledger.Row_rejected _)) -> ()
   | Error other ->
     Alcotest.failf "expected Read_failed, got %s" (Candle_ledger.update_error_to_string Fun.id other)
   | Ok () -> Alcotest.fail "an update ran on a ledger nobody can read");
  Alcotest.(check string) "the file is untouched" before (file_text base_path)
;;

let test_only_recovery_cuts_a_torn_tail () =
  with_base_path
  @@ fun base_path ->
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-a" ], ())) in
  append_raw base_path "{\"kind\":\"snapshot\",\"at\":\"2026";
  (match Candle_ledger.read ~base_path with
   | Error (Candle_ledger.Store_failed _) -> ()
   | Error other ->
     Alcotest.failf "expected Store_failed, got %s" (Candle_ledger.read_error_to_string other)
   | Ok _ -> Alcotest.fail "a torn tail was read as if it were a row");
  (match Candle_ledger.update ~base_path (fun _ -> Ok ([ snapshot "goal-b" ], ())) with
   | Error (Candle_ledger.Read_failed (Candle_ledger.Store_failed _)) -> ()
   | Error other ->
     Alcotest.failf "expected Read_failed, got %s" (Candle_ledger.update_error_to_string Fun.id other)
   | Ok () -> Alcotest.fail "an update wrote after a torn tail");
  let recovered =
    match Candle_ledger.recover_at_start ~base_path with
    | Ok view -> view
    | Error error -> Alcotest.failf "%s" (Candle_ledger.read_error_to_string error)
  in
  Alcotest.(check (list string))
    "recovery keeps the full rows"
    [ "goal-a" ]
    (goal_ids (Candle_ledger.events recovered));
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-b" ], ())) in
  Alcotest.(check (list string))
    "appends follow the cut"
    [ "goal-a"; "goal-b" ]
    (goal_ids (Candle_ledger.events (read_ok base_path)))
;;

let () =
  Alcotest.run
    "candle_ledger"
    [ ( "read"
      , [ Alcotest.test_case "a missing file is an empty ledger" `Quick
            test_a_missing_file_is_an_empty_ledger
        ; Alcotest.test_case "a row that does not read fails the read" `Quick
            test_a_row_that_does_not_read_fails_the_read
        ; Alcotest.test_case "only recovery cuts a torn tail" `Quick
            test_only_recovery_cuts_a_torn_tail
        ] )
    ; ( "update"
      , [ Alcotest.test_case "rows are appended in order" `Quick
            test_updates_append_rows_in_order
        ; Alcotest.test_case "decide sees what is already there" `Quick
            test_decide_sees_what_is_already_there
        ; Alcotest.test_case "no events writes nothing" `Quick test_no_events_writes_nothing
        ; Alcotest.test_case "a refusal writes nothing" `Quick test_a_refusal_writes_nothing
        ; Alcotest.test_case "a writer that lost the race reads again" `Quick
            test_a_writer_that_lost_the_race_reads_again
        ] )
    ]
;;
