(** Row codec tests for the Candle ledger (RFC-goal-candle-ledger 3.1). *)

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)
let now = at "2026-09-29T06:00:00Z"
let event body : E.t = { at = now; body }

let snapshot
  ?(goal_id = "goal-1")
  ?(due_date = Some "2026-09-26")
  ?(title = "Ship the ledger")
  ?(metric = Some "tests")
  ?(target_value = None)
  ?(linked_task_ids = [ "task-1"; "task-2" ])
  ()
  =
  event
    (E.Snapshot
       { goal_id
       ; request_id = "req-1"
       ; criterion_revision = "rev-1"
       ; passed_at = at "2026-09-28T06:32:00Z"
       ; goal_created_at = at "2026-09-20T01:00:00Z"
       ; due_date
       ; title
       ; metric
       ; target_value
       ; linked_task_ids
       })
;;

let payout_owed ?(goal_id = "goal-1") () =
  event
    (E.Payout_owed
       { goal_id
       ; request_id = "req-1"
       ; passed_at = at "2026-09-28T06:32:00Z"
       ; confirmed_at = at "2026-09-29T05:00:00Z"
       })
;;

let event_testable =
  Alcotest.testable
    (fun formatter (row : E.t) ->
       Format.pp_print_string formatter (Yojson.Safe.to_string (E.to_yojson row)))
    ( = )
;;

let line_of row = ok_or_fail (E.to_line row)

let test_the_row_format () =
  Alcotest.(check string)
    "snapshot"
    ({|{"kind":"snapshot","at":"2026-09-29T06:00:00Z","goal_id":"goal-1","request_id":"req-1",|}
     ^ {|"criterion_revision":"rev-1","passed_at":"2026-09-28T06:32:00Z","goal_created_at":"2026-09-20T01:00:00Z",|}
     ^ {|"due_date":"2026-09-26","title":"Ship the ledger","metric":"tests","target_value":null,|}
     ^ {|"linked_task_ids":["task-1","task-2"]}|})
    (line_of (snapshot ()));
  Alcotest.(check string)
    "payout_owed"
    ({|{"kind":"payout_owed","at":"2026-09-29T06:00:00Z","goal_id":"goal-1","request_id":"req-1",|}
     ^ {|"passed_at":"2026-09-28T06:32:00Z","confirmed_at":"2026-09-29T05:00:00Z"}|})
    (line_of (payout_owed ()))
;;

let round_trips label row =
  let written = line_of row in
  Alcotest.check event_testable label row (ok_or_fail (E.of_line written));
  Alcotest.(check string)
    (label ^ " writes the same line again")
    written
    (line_of (ok_or_fail (E.of_line written)))
;;

let test_a_row_reads_back_as_written () =
  round_trips "typical" (snapshot ());
  round_trips "nothing optional" (snapshot ~due_date:None ~metric:None ~linked_task_ids:[] ());
  round_trips "an empty title" (snapshot ~title:"" ());
  round_trips "a payout owed" (payout_owed ())
;;

(* The due date is a fact as the Goal held it. The ledger does not decide what
   is a date, so text that is not one is written and read back untouched. *)
let test_a_due_date_is_kept_as_the_goal_held_it () =
  List.iter
    (fun raw -> round_trips (Printf.sprintf "due_date %S" raw) (snapshot ~due_date:(Some raw) ()))
    [ ""; "TBD"; "2026-9-3"; " 2026-09-26"; "2026-02-30"; "2026-09-26T10:00:00Z"; "다음 주" ]
;;

(* A row is one physical line whatever the Goal's text holds, because the file
   is read line by line. *)
let test_a_row_stays_one_line () =
  let title = "line one\nline two\r\n\ttabbed \"quoted\" back\\slash \xe2\x80\xa8 unicode \xed\x95\x9c\xea\xb8\x80" in
  let row = snapshot ~title ~metric:(Some "a\nb") () in
  let written = line_of row in
  Alcotest.(check bool) "no newline inside the row" false (String.contains written '\n');
  Alcotest.(check bool) "no carriage return inside the row" false (String.contains written '\r');
  Alcotest.check event_testable "reads back" row (ok_or_fail (E.of_line written))
;;

let valid = line_of (snapshot ())

let replace_first ~sub ~by text =
  let n = String.length sub in
  let rec find i =
    if i + n > String.length text
    then Alcotest.failf "the sample line has no %S" sub
    else if String.equal (String.sub text i n) sub
    then i
    else find (i + 1)
  in
  let i = find 0 in
  String.sub text 0 i ^ by ^ String.sub text (i + n) (String.length text - i - n)
;;

let valid_owed = line_of (payout_owed ())

let test_the_valid_line_used_below_does_read () =
  Alcotest.(check bool) "valid" true (Result.is_ok (E.of_line valid));
  Alcotest.(check bool) "valid payout_owed" true (Result.is_ok (E.of_line valid_owed))
;;

let test_a_row_that_is_not_exactly_the_schema_is_refused () =
  List.iter
    (fun (label, text) ->
       Alcotest.(check bool) label true (Result.is_error (E.of_line text)))
    [ "unknown kind", replace_first ~sub:{|"snapshot"|} ~by:{|"refunded"|} valid
    ; "missing at", replace_first ~sub:{|"at":"2026-09-29T06:00:00Z",|} ~by:"" valid
    ; ( "missing a field"
      , replace_first ~sub:{|"request_id":"req-1",|} ~by:"" valid )
    ; ( "extra field"
      , replace_first ~sub:{|"linked_task_ids"|} ~by:{|"note":"x","linked_task_ids"|} valid )
    ; ( "repeated field"
      , replace_first ~sub:{|"title":|} ~by:{|"goal_id":"goal-2","title":|} valid )
    ; ( "time with an offset"
      , replace_first ~sub:{|"at":"2026-09-29T06:00:00Z"|} ~by:{|"at":"2026-09-29T15:00:00+09:00"|} valid )
    ; ( "time with a fraction"
      , replace_first ~sub:{|"at":"2026-09-29T06:00:00Z"|} ~by:{|"at":"2026-09-29T06:00:00.5Z"|} valid )
    ; ( "passed_at is not a time"
      , replace_first ~sub:{|"passed_at":"2026-09-28T06:32:00Z"|} ~by:{|"passed_at":"yesterday"|} valid )
    ; ( "blank goal id"
      , replace_first ~sub:{|"goal_id":"goal-1"|} ~by:{|"goal_id":" "|} valid )
    ; ( "blank task id"
      , replace_first ~sub:{|["task-1","task-2"]|} ~by:{|["task-1",""]|} valid )
    ; ( "due_date is a number"
      , replace_first ~sub:{|"due_date":"2026-09-26"|} ~by:{|"due_date":20260926|} valid )
    ; ( "linked_task_ids is not a list"
      , replace_first ~sub:{|["task-1","task-2"]|} ~by:{|"task-1"|} valid )
    ; ( "title is null"
      , replace_first ~sub:{|"title":"Ship the ledger"|} ~by:{|"title":null|} valid )
    ; ( "payout_owed missing confirmed_at"
      , replace_first ~sub:{|,"confirmed_at":"2026-09-29T05:00:00Z"|} ~by:"" valid_owed )
    ; ( "payout_owed with a snapshot field"
      , replace_first ~sub:{|"request_id"|} ~by:{|"title":"x","request_id"|} valid_owed )
    ; ( "payout_owed with a blank request id"
      , replace_first ~sub:{|"request_id":"req-1"|} ~by:{|"request_id":""|} valid_owed )
    ; ( "payout_owed confirmed_at with an offset"
      , replace_first
          ~sub:{|"confirmed_at":"2026-09-29T05:00:00Z"|}
          ~by:{|"confirmed_at":"2026-09-29T14:00:00+09:00"|}
          valid_owed )
    ; "snapshot fields on a payout_owed kind", replace_first ~sub:{|"snapshot"|} ~by:{|"payout_owed"|} valid
    ; "not an object", "[]"
    ; "text after the row", valid ^ " x"
    ; "a second row on the line", valid ^ valid
    ; "empty line", ""
    ; "not JSON", "snapshot"
    ]
;;

let test_an_event_that_would_not_read_back_is_not_written () =
  Alcotest.(check bool)
    "blank goal id"
    true
    (Result.is_error (E.to_line (snapshot ~goal_id:" " ())));
  Alcotest.(check bool)
    "blank task id"
    true
    (Result.is_error (E.to_line (snapshot ~linked_task_ids:[ "task-1"; " " ] ())))
;;

let () =
  Alcotest.run
    "candle_event"
    [ ( "codec"
      , [ Alcotest.test_case "the row format" `Quick test_the_row_format
        ; Alcotest.test_case "a row reads back as written" `Quick test_a_row_reads_back_as_written
        ; Alcotest.test_case
            "a due date is kept as the Goal held it"
            `Quick
            test_a_due_date_is_kept_as_the_goal_held_it
        ; Alcotest.test_case "a row stays one line" `Quick test_a_row_stays_one_line
        ] )
    ; ( "strict reading"
      , [ Alcotest.test_case
            "the valid line used below does read"
            `Quick
            test_the_valid_line_used_below_does_read
        ; Alcotest.test_case
            "a row that is not exactly the schema is refused"
            `Quick
            test_a_row_that_is_not_exactly_the_schema_is_refused
        ; Alcotest.test_case
            "an event that would not read back is not written"
            `Quick
            test_an_event_that_would_not_read_back_is_not_written
        ] )
    ]
;;
