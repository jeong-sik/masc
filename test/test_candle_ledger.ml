(** The Candle ledger file (RFC-goal-candle-ledger 3.1): appended rows, a
    torn tail, a row that does not read, and a second writer getting in first. *)

module E = Candle_event

(* Helper mode. A test that needs another process to hold the ledger's lock
   starts this same executable again with this variable set. That copy takes
   the lock, says so, and holds it until its stdin closes. *)
let lock_holder_variable = "CANDLE_LEDGER_TEST_HOLD_LOCK"

let () =
  match Sys.getenv_opt lock_holder_variable with
  | None -> ()
  | Some lock_path ->
    let fd = Unix.openfile lock_path [ Unix.O_RDWR ] 0 in
    Unix.lockf fd Unix.F_LOCK 0;
    print_string "locked\n";
    flush stdout;
    (match input_line stdin with
     | (_ : string) -> ()
     | exception End_of_file -> ());
    exit 0
;;

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
        ; verification_run_id = "run-1"
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
  List.filter_map
    (fun (event : E.t) ->
       match event.body with
       | E.Snapshot { goal_id; _ }
       | E.Payout_owed { goal_id; _ }
       | E.Candidates { goal_id; _ }
       | E.Unattributed { goal_id; _ }
       | E.Payout_failed { goal_id; _ } -> Some goal_id
       | E.Paid p -> Some p.identity.goal_id
       | E.Half_life_set _ -> None
       | E.Equipped _ | E.Purchased _ -> Alcotest.fail "a purchase has no Goal identity")
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

let with_base_path_and_clock f =
  Eio_main.run
  @@ fun env ->
  Fs_compat.set_fs (Eio.Stdenv.fs env);
  let base_path = temp_dir () in
  Fun.protect
    ~finally:(fun () -> rm_rf base_path)
    (fun () -> f (Eio.Stdenv.clock env) base_path)
;;

let with_base_path f = with_base_path_and_clock (fun _clock base_path -> f base_path)

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

let funding_rows (at : Candle_time.t) (payment : Candle_payment.t) : Candle_event.t list =
  let identity = payment.identity in
  let task_keepers = List.map2 (fun (relation : Candle_appraisal.task_relation)
      (allocation : Candle_payment.allocation) -> relation.task_id, allocation.keeper)
      payment.relations payment.allocations in
  let task_ids = List.map fst task_keepers in
  [ {Candle_event.at;body=Candle_event.Half_life_set Candle_decay.Off}
  ; {Candle_event.at;body=Candle_event.Snapshot
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;criterion_revision="funding-proof";
       passed_at=at;goal_created_at=(match Candle_time.of_rfc3339 "1970-01-01T00:00:00Z" with
         | Ok value -> value | Error detail -> Alcotest.fail detail);
       due_date=None;title="Completed funding fixture";metric=Some "completed";
       target_value=Some "1";linked_task_ids=task_ids}}
  ; {Candle_event.at;body=Candle_event.Payout_owed
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;passed_at=at;confirmed_at=at}}
  ; {Candle_event.at;body=Candle_event.Candidates
      {goal_id=identity.goal_id;request_id=identity.request_id;
       verification_run_id=identity.verification_run_id;
       tasks=List.map (fun (id, keeper) -> id, Candle_event.Found
         {title="Completed contribution";assignee=Some keeper;
          status=Candle_event.Done {completed_at=at}}) task_keepers;
       candidate_task_ids=task_ids;candidate_keepers=List.map snd task_keepers;
       candidate_task_keepers=List.map (fun (id, keeper) -> id, Some keeper) task_keepers}}
  ; {Candle_event.at;body=Candle_event.Paid payment}
  ]
;;

(* Persisted receipt fixtures, intentionally independent of [make]. The first
   records nearest rounding; the second gives a tied remainder to the last
   name. They simulate older arithmetic choices in the same row format. The
   current producer floors deductions and gives equal remainders to the first
   name, but that must not rewrite or make these stored facts unreadable. *)
let stored_rounded_payment =
  {|{"kind":"paid","at":"2026-09-29T06:00:00Z","goal_id":"past-rounded","request_id":"request-rounded","verification_run_id":"verified-rounded","grade":"small","total_milli":2001,"grade_trace":{"run_id":"grade-rounded","slot_id":"slot-grade"},"relations":[{"task_id":"task-a","relation":"related","trace":{"run_id":"relation-a","slot_id":"slot-relation"}}],"weights_trace":{"run_id":"weights-rounded","slot_id":"slot-weights"},"weight_max":10,"deduction_rate":10,"deduction_floor":200,"overdue_hours":30,"coefficient":700,"allocations":[{"keeper":"keeper-a","weight":1,"share_milli":2001,"amount_milli":1401}]}|}
;;

let stored_tied_payment =
  {|{"kind":"paid","at":"2026-09-29T06:00:00Z","goal_id":"past-tied","request_id":"request-tied","verification_run_id":"verified-tied","grade":"trivial","total_milli":1000,"grade_trace":{"run_id":"grade-tied","slot_id":"slot-grade"},"relations":[{"task_id":"task-a","relation":"related","trace":{"run_id":"relation-a","slot_id":"slot-relation"}},{"task_id":"task-b","relation":"related","trace":{"run_id":"relation-b","slot_id":"slot-relation"}},{"task_id":"task-c","relation":"related","trace":{"run_id":"relation-c","slot_id":"slot-relation"}}],"weights_trace":{"run_id":"weights-tied","slot_id":"slot-weights"},"weight_max":10,"deduction_rate":10,"deduction_floor":200,"overdue_hours":0,"coefficient":1000,"allocations":[{"keeper":"keeper-a","weight":1,"share_milli":333,"amount_milli":333},{"keeper":"keeper-b","weight":1,"share_milli":333,"amount_milli":333},{"keeper":"keeper-c","weight":1,"share_milli":334,"amount_milli":334}]}|}
;;

let payment_of_event (row : E.t) =
  match row.body with
  | E.Paid payment -> payment
  | E.Snapshot _ | E.Payout_owed _ | E.Candidates _ | E.Unattributed _
  | E.Payout_failed _ | E.Half_life_set _ | E.Purchased _ | E.Equipped _ ->
    Alcotest.fail "expected a Paid receipt"
;;

let balance_of_view view =
  match Candle_balance.of_events ~at:(at "2026-09-30T00:00:00Z") (Candle_ledger.events view) with
  | Ok balance -> balance
  | Error error -> Alcotest.fail (Candle_balance.error_to_string error)
;;

let test_stored_payments_replay_but_new_appends_require_current_arithmetic () =
  with_base_path @@ fun base_path ->
  let with_admission line =
    let row = ok_or_fail (E.of_line line) in
    let prefix = funding_rows row.at (payment_of_event row)
      |> List.filter (fun (event : E.t) -> match event.body with E.Paid _ -> false | E.Snapshot _ | E.Payout_owed _ | E.Candidates _ | E.Unattributed _
        | E.Payout_failed _ | E.Half_life_set _ | E.Purchased _ | E.Equipped _ -> true)
      |> List.map (fun row -> ok_or_fail (E.to_line row) ^ "\n") in
    String.concat "" prefix ^ line ^ "\n" in
  let bytes = with_admission stored_rounded_payment ^ with_admission stored_tied_payment in
  append_raw base_path bytes;
  let view = read_ok base_path in
  let stored = Candle_ledger.events view in
  let payments = List.filter (fun (event : E.t) -> match event.body with E.Paid _ -> true | E.Snapshot _ | E.Payout_owed _ | E.Candidates _ | E.Unattributed _
        | E.Payout_failed _ | E.Half_life_set _ | E.Purchased _ | E.Equipped _ -> false) stored in
  let balance = balance_of_view view in
  Alcotest.(check int) "stored rounded amount and first tie share are credited"
    1734 (Candle_balance.balance balance ~keeper:"keeper-a");
  Alcotest.(check int) "middle tie share is retained"
    333 (Candle_balance.balance balance ~keeper:"keeper-b");
  Alcotest.(check int) "stored remainder recipient is retained"
    334 (Candle_balance.balance balance ~keeper:"keeper-c");
  Alcotest.(check string) "issuance uses recorded credits, not nominal totals"
    "2401" (Candle_balance.supply balance).issued_milli;
  (match Candle_ledger.recover_at_start ~base_path with
   | Ok recovered ->
     Alcotest.(check bool) "startup recovery retains both receipts" true
       (Candle_ledger.events recovered = stored)
   | Error error -> Alcotest.fail (Candle_ledger.read_error_to_string error));
  List.iter
    (fun row ->
      let line = ok_or_fail (E.to_line row) in
      Alcotest.(check bool) "receipt serialization retains the stored fields" true
        (ok_or_fail (E.of_line line) = row);
      (match Candle_ledger.update ~base_path (fun _ -> Ok ([row], ())) with
       | Error (Candle_ledger.Event_unwritable detail) ->
         Alcotest.(check string) "new issuance still checks arithmetic"
           "new payment arithmetic does not match its evidence" detail
       | Error other -> Alcotest.fail (Candle_ledger.update_error_to_string Fun.id other)
       | Ok () -> Alcotest.fail "old arithmetic was accepted for a new payment");
      Alcotest.(check string) "read and refused append never rewrite history"
        bytes (file_text base_path))
    payments;
  let rounded = payment_of_event (List.hd payments) in
  let current =
    Candle_payment.make
      ~identity:{ rounded.identity with goal_id = "new-current" }
      ~grade:rounded.grade ~total_milli:rounded.total_milli
      ~grade_trace:rounded.grade_trace ~relations:rounded.relations
      ~weights_trace:rounded.weights_trace ~weight_max:rounded.weight_max
      ~deduction_rate:rounded.deduction_rate ~deduction_floor:rounded.deduction_floor
      ~overdue_hours:rounded.overdue_hours
      ~weights:(List.map (fun (a : Candle_payment.allocation) -> a.keeper, a.weight)
        rounded.allocations)
    |> ok_or_fail
  in
  Alcotest.(check (list int)) "new payment still uses today's floor rule"
    [1400] (List.map (fun (a : Candle_payment.allocation) -> a.amount_milli) current.allocations);
  update_ok base_path (fun _ -> Ok (funding_rows (at "2026-09-30T00:00:00Z") current, ()));
  Alcotest.(check bool) "valid new payment appends after unchanged history" true
    (String.starts_with ~prefix:bytes (file_text base_path));
  let after = balance_of_view (read_ok base_path) in
  Alcotest.(check int) "old recorded credit and new calculated credit coexist"
    3134 (Candle_balance.balance after ~keeper:"keeper-a")
;;

let test_malformed_paid_receipts_still_fail_the_whole_ledger_read () =
  let rounded = Yojson.Safe.from_string stored_rounded_payment in
  let tied = Yojson.Safe.from_string stored_tied_payment in
  let replace key value json =
    let fields = Yojson.Safe.Util.to_assoc json in
    `Assoc (List.map (fun (name, old) -> name, if name = key then value else old) fields)
  in
  let allocation index key value json =
    let rows = Yojson.Safe.Util.(json |> member "allocations" |> to_list) in
    replace "allocations"
      (`List (List.mapi (fun i row -> if i = index then replace key value row else row) rows)) json
  in
  let cases =
    [ "negative total", replace "total_milli" (`Int (-1)) rounded
    ; "negative rate", replace "deduction_rate" (`Int (-1)) rounded
    ; "rate above thousandths", replace "deduction_rate" (`Int 1001) rounded
    ; "negative floor", replace "deduction_floor" (`Int (-1)) rounded
    ; "floor above thousandths", replace "deduction_floor" (`Int 1001) rounded
    ; "negative hours", replace "overdue_hours" (`Int (-1)) rounded
    ; "coefficient below floor", replace "coefficient" (`Int 199) rounded
    ; "coefficient above thousandths", replace "coefficient" (`Int 1001) rounded
    ; "empty allocations", replace "allocations" (`List []) rounded
    ; "duplicate recipient", allocation 1 "keeper" (`String "keeper-a") tied
    ; "blank recipient", allocation 0 "keeper" (`String " ") rounded
    ; "invalid weight bound", replace "weight_max" (`Int 0) rounded
    ; "negative weight", allocation 0 "weight" (`Int (-1)) rounded
    ; "weight above its bound", allocation 0 "weight" (`Int 11) rounded
    ; "no positive weight", allocation 0 "weight" (`Int 0) rounded
    ; "zero weight has a share", allocation 0 "weight" (`Int 0) tied
    ; "negative share", allocation 0 "share_milli" (`Int (-1)) rounded
    ; "negative credit", allocation 0 "amount_milli" (`Int (-1)) rounded
    ; "credit exceeds share", allocation 0 "amount_milli" (`Int 2002) rounded
    ; "shares exceed total", allocation 0 "share_milli" (`Int 2002) rounded
    ; "shares below total", allocation 0 "share_milli" (`Int 2000) rounded
    ; "overflowing share sum",
      (tied |> replace "total_milli" (`Int max_int)
       |> allocation 0 "share_milli" (`Int max_int)
       |> allocation 1 "share_milli" (`Int max_int))
    ; "wrong JSON amount kind", allocation 0 "amount_milli" (`String "1401") rounded
    ]
  in
  List.iter (fun (label, damaged) ->
    with_base_path @@ fun base_path ->
    let before = ok_or_fail (E.to_line (snapshot "before-damage")) ^ "\n"
      ^ Yojson.Safe.to_string damaged ^ "\n" in
    append_raw base_path before;
    (match Candle_ledger.read ~base_path with
     | Error (Candle_ledger.Row_rejected {line_number = 2; _}) -> ()
     | Error error -> Alcotest.failf "%s: %s" label (Candle_ledger.read_error_to_string error)
     | Ok _ -> Alcotest.failf "%s was accepted or skipped" label);
    Alcotest.(check string) (label ^ " does not repair or rewrite the file")
      before (file_text base_path)) cases
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

(* Starts the lock holder and returns the function that lets it go. *)
let start_lock_holder base_path =
  let lock_path = Fs_compat.private_jsonl_lock_path (Candle_ledger.path ~base_path) in
  let stdin_read, stdin_write = Unix.pipe ~cloexec:true () in
  let stdout_read, stdout_write = Unix.pipe ~cloexec:true () in
  let environment =
    Array.append [| lock_holder_variable ^ "=" ^ lock_path |] (Unix.environment ())
  in
  let pid =
    Unix.create_process_env
      Sys.executable_name
      [| Sys.executable_name |]
      environment
      stdin_read
      stdout_write
      Unix.stderr
  in
  Unix.close stdin_read;
  Unix.close stdout_write;
  let from_holder = Unix.in_channel_of_descr stdout_read in
  (match input_line from_holder with
   | "locked" -> ()
   | other -> Alcotest.failf "the lock holder said %S" other);
  let rec wait_for_exit () =
    match Unix.waitpid [] pid with
    | (_ : int * Unix.process_status) -> ()
    | exception Unix.Unix_error (Unix.EINTR, _, _) -> wait_for_exit ()
  in
  fun () ->
    Unix.close stdin_write;
    wait_for_exit ();
    close_in_noerr from_holder
;;

let within clock label f =
  match Eio.Time.with_timeout clock 5. (fun () -> Ok (f ())) with
  | Ok value -> value
  | Error `Timeout -> Alcotest.failf "%s waited for the other process's lock" label
;;

(* A process that holds the lock can hold it as long as it likes. Waiting for it
   in a loop would hang the caller with no answer, so the ledger says at once
   that it is locked and the caller decides when to ask again. *)
let test_a_lock_another_process_holds_is_reported_not_waited_for () =
  with_base_path_and_clock
  @@ fun clock base_path ->
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-a" ], ())) in
  let before = file_text base_path in
  let release = start_lock_holder base_path in
  Fun.protect
    ~finally:release
    (fun () ->
       (match within clock "read" (fun () -> Candle_ledger.read ~base_path) with
        | Error (Candle_ledger.Locked _) -> ()
        | Error other ->
          Alcotest.failf "expected Locked, got %s" (Candle_ledger.read_error_to_string other)
        | Ok _ -> Alcotest.fail "a read went through a lock another process holds");
       (match
          within clock "update" (fun () ->
            Candle_ledger.update ~base_path (fun _ -> Ok ([ snapshot "goal-b" ], ())))
        with
        | Error (Candle_ledger.Read_failed (Candle_ledger.Locked _)) -> ()
        | Error other ->
          Alcotest.failf
            "expected Locked, got %s"
            (Candle_ledger.update_error_to_string Fun.id other)
        | Ok () -> Alcotest.fail "an update went through a lock another process holds");
       Alcotest.(check string) "the file is untouched" before (file_text base_path));
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-b" ], ())) in
  Alcotest.(check (list string))
    "once the other process lets go the ledger works"
    [ "goal-a"; "goal-b" ]
    (goal_ids (Candle_ledger.events (read_ok base_path)))
;;

(* The other process takes the lock after the read and before the append. *)
let test_a_lock_taken_between_the_read_and_the_append_is_reported () =
  with_base_path_and_clock
  @@ fun clock base_path ->
  let () = update_ok base_path (fun _ -> Ok ([ snapshot "goal-a" ], ())) in
  let before = file_text base_path in
  let release = ref (fun () -> ()) in
  let result =
    within clock "update" (fun () ->
      Candle_ledger.update ~base_path (fun _ ->
        release := start_lock_holder base_path;
        Ok ([ snapshot "goal-b" ], ())))
  in
  !release ();
  (match result with
   | Error (Candle_ledger.Write_locked _) -> ()
   | Error other ->
     Alcotest.failf
       "expected Write_locked, got %s"
       (Candle_ledger.update_error_to_string Fun.id other)
   | Ok () -> Alcotest.fail "an append went through a lock another process took");
  Alcotest.(check string) "the file is untouched" before (file_text base_path)
;;

let () =
  Alcotest.run
    "candle_ledger"
    [ ( "read"
      , [ Alcotest.test_case "a missing file is an empty ledger" `Quick
            test_a_missing_file_is_an_empty_ledger
        ; Alcotest.test_case "stored credits survive changed rounding; new appends validate" `Quick
            test_stored_payments_replay_but_new_appends_require_current_arithmetic
        ; Alcotest.test_case "malformed Paid receipts fail the whole ledger read" `Quick
            test_malformed_paid_receipts_still_fail_the_whole_ledger_read
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
        ; Alcotest.test_case "a lock another process holds is reported, not waited for" `Quick
            test_a_lock_another_process_holds_is_reported_not_waited_for
        ; Alcotest.test_case "a lock taken between the read and the append is reported" `Quick
            test_a_lock_taken_between_the_read_and_the_append_is_reported
        ] )
    ]
;;
