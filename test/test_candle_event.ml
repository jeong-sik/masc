(** Row codec tests for the Candle ledger (RFC-goal-candle-ledger 3.1). *)

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)

let keeper name =
  match Candle_keeper.of_string name with
  | Some value -> value
  | None -> Alcotest.failf "blank keeper name %S" name
;;

let milli amount =
  match Candle_milli.of_int amount with
  | Ok value -> value
  | Error error -> Alcotest.failf "%s" (Candle_milli.error_to_string error)
;;

let date text =
  match Candle_time.Date.of_string text with
  | Some value -> value
  | None -> Alcotest.failf "not a date: %S" text
;;

let now = at "2026-09-29T06:00:00Z"
let due_date = E.Due_date (date "2026-09-26")

let line ?(weight = 1) ?(coefficient = 1000) ~keeper:name ~share ~amount () : E.payout_line =
  { keeper = keeper name
  ; weight
  ; share = milli share
  ; coefficient_permille = coefficient
  ; amount = milli amount
  }
;;

let deduction ?(rate = 10) ?(floor = 200) () : E.deduction =
  { clock = at "2026-09-28T06:32:00Z"
  ; due = due_date
  ; rate_permille = rate
  ; floor_permille = floor
  }
;;

let make_paid ?(goal_id = "goal-1") ?(request_id = "req-1") ?(lane_slot = "slot-a")
  ?(total = 10_000) ?(deduction = deduction ()) lines =
  E.make_paid
    ~goal_id
    ~request_id
    ~grade:E.Medium
    ~total:(milli total)
    ~lane_slot
    ~lines
    ~deduction
;;

let two_lines =
  [ line ~keeper:"alice" ~weight:3 ~share:7500 ~coefficient:700 ~amount:5250 ()
  ; line ~keeper:"bob" ~share:2500 ~coefficient:700 ~amount:1750 ()
  ]
;;

let event body : E.t = { at = now; body }

let one_of_each_kind : E.t list =
  [ event
      (E.Snapshot
         { goal_id = "goal-1"
         ; request_id = "req-1"
         ; criterion_revision = "rev-1"
         ; passed_at = at "2026-09-28T06:32:00Z"
         ; goal_created_at = at "2026-09-20T01:00:00Z"
         ; due = due_date
         ; title = "Ship the ledger"
         ; metric = Some "tests"
         ; target_value = None
         ; linked_task_ids = [ "task-1"; "task-2" ]
         })
  ; event
      (E.Payout_owed
         { goal_id = "goal-1"
         ; request_id = "req-1"
         ; passed_at = at "2026-09-28T06:32:00Z"
         ; tasks =
             [ { task_id = "task-1"
               ; title = "Write the codec"
               ; assignee = Some (keeper "alice")
               ; state = E.Done
               ; completed_at = Some (at "2026-09-27T01:00:00Z")
               }
             ; { task_id = "task-2"
               ; title = "Review it"
               ; assignee = None
               ; state = E.Awaiting_verification
               ; completed_at = None
               }
             ]
         ; candidates = [ keeper "alice" ]
         })
  ; event (E.Payout_failed { goal_id = "goal-1"; request_id = "req-1"; reason = E.Due_unreadable })
  ; event (E.Paid (ok_or_fail (make_paid two_lines)))
  ; event (E.Unattributed { goal_id = "goal-1"; reason = E.No_candidate })
  ; event
      (E.Purchased { keeper = keeper "alice"; item = Candle_item.Glasses; cost = milli 500 })
  ; event (E.Equipped { keeper = keeper "alice"; wear = Candle_item.Wear Candle_item.Crown })
  ]

(* A new constructor stops this match compiling, and the coverage check below
   then fails until [one_of_each_kind] has a row for it. *)
let kind_index : E.body -> int = function
  | E.Snapshot _ -> 0
  | E.Payout_owed _ -> 1
  | E.Payout_failed _ -> 2
  | E.Paid _ -> 3
  | E.Unattributed _ -> 4
  | E.Purchased _ -> 5
  | E.Equipped _ -> 6
;;

let event_testable =
  Alcotest.testable
    (fun formatter (row : E.t) ->
       Format.pp_print_string formatter (Yojson.Safe.to_string (E.to_yojson row)))
    ( = )
;;

let line_of row = ok_or_fail (E.to_line row)

let test_every_kind_has_a_sample () =
  let indexes = List.sort_uniq Int.compare (List.map (fun (row : E.t) -> kind_index row.body) one_of_each_kind) in
  Alcotest.(check (list int)) "one row per constructor" [ 0; 1; 2; 3; 4; 5; 6 ] indexes
;;

let test_every_kind_reads_back_as_written () =
  List.iter
    (fun (row : E.t) ->
       let written = line_of row in
       let label = E.kind row.body in
       Alcotest.check event_testable label row (ok_or_fail (E.of_line written));
       Alcotest.(check string)
         (label ^ " writes the same line again")
         written
         (line_of (ok_or_fail (E.of_line written))))
    one_of_each_kind
;;

let test_the_row_format () =
  let expect label expected row = Alcotest.(check string) label expected (line_of row) in
  expect
    "purchased"
    {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":500}|}
    (event (E.Purchased { keeper = keeper "alice"; item = Candle_item.Glasses; cost = milli 500 }));
  expect
    "equipped, back to the default"
    {|{"kind":"equipped","at":"2026-09-29T06:00:00Z","keeper":"alice","slot":"face","item":"default"}|}
    (event (E.Equipped { keeper = keeper "alice"; wear = Candle_item.Default Candle_item.Face }));
  expect
    "payout_failed"
    {|{"kind":"payout_failed","at":"2026-09-29T06:00:00Z","goal_id":"goal-1","request_id":"req-1","reason":"due_unreadable"}|}
    (event (E.Payout_failed { goal_id = "goal-1"; request_id = "req-1"; reason = E.Due_unreadable }));
  expect
    "unattributed"
    {|{"kind":"unattributed","at":"2026-09-29T06:00:00Z","goal_id":"goal-1","reason":"no_candidate"}|}
    (event (E.Unattributed { goal_id = "goal-1"; reason = E.No_candidate }));
  expect
    "paid"
    ({|{"kind":"paid","at":"2026-09-29T06:00:00Z","goal_id":"goal-1","request_id":"req-1","grade":"medium","total_milli":10000,"lane_slot":"slot-a",|}
     ^ {|"lines":[{"keeper":"alice","weight":3,"share_milli":7500,"coefficient_permille":700,"amount_milli":5250},|}
     ^ {|{"keeper":"bob","weight":1,"share_milli":2500,"coefficient_permille":700,"amount_milli":1750}],|}
     ^ {|"deduction":{"clock":"2026-09-28T06:32:00Z","due":{"state":"date","date":"2026-09-26"},"rate_permille":10,"floor_permille":200}}|})
    (event (E.Paid (ok_or_fail (make_paid two_lines))))
;;

let valid_purchase = {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":500}|}

let snapshot_with ~due ~goal_id =
  Printf.sprintf
    {|{"kind":"snapshot","at":"2026-09-29T06:00:00Z","goal_id":%S,"request_id":"req-1","criterion_revision":"rev-1","passed_at":"2026-09-28T06:32:00Z","goal_created_at":"2026-09-20T01:00:00Z","due":%s,"title":"t","metric":null,"target_value":null,"linked_task_ids":[]}|}
    goal_id
    due
;;

let test_the_valid_lines_used_below_do_read () =
  Alcotest.(check bool) "purchase" true (Result.is_ok (E.of_line valid_purchase));
  Alcotest.(check bool)
    "snapshot"
    true
    (Result.is_ok (E.of_line (snapshot_with ~due:{|{"state":"none"}|} ~goal_id:"goal-1")))
;;

let test_a_row_that_is_not_exactly_the_schema_is_refused () =
  List.iter
    (fun (label, text) ->
       Alcotest.(check bool) label true (Result.is_error (E.of_line text)))
    [ ( "unknown kind"
      , {|{"kind":"refunded","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":500}|} )
    ; "missing at", {|{"kind":"purchased","keeper":"alice","item":"glasses","cost_milli":500}|}
    ; ( "extra field"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":500,"note":"x"}|} )
    ; ( "repeated field"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":500,"cost_milli":600}|} )
    ; ( "float amount"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":500.0}|} )
    ; ( "string amount"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":"500"}|} )
    ; ( "negative amount"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"glasses","cost_milli":-1}|} )
    ; ( "unknown item"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"alice","item":"top_hat","cost_milli":500}|} )
    ; ( "keeper not canonical"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":"Alice","item":"glasses","cost_milli":500}|} )
    ; ( "blank keeper"
      , {|{"kind":"purchased","at":"2026-09-29T06:00:00Z","keeper":" ","item":"glasses","cost_milli":500}|} )
    ; ( "time with an offset"
      , {|{"kind":"purchased","at":"2026-09-29T15:00:00+09:00","keeper":"alice","item":"glasses","cost_milli":500}|} )
    ; "not an object", {|[]|}
    ; "text after the row", valid_purchase ^ " x"
    ; "empty line", ""
    ; ( "item in the wrong slot"
      , {|{"kind":"equipped","at":"2026-09-29T06:00:00Z","keeper":"alice","slot":"face","item":"crown"}|} )
    ; ( "unknown slot"
      , {|{"kind":"equipped","at":"2026-09-29T06:00:00Z","keeper":"alice","slot":"foot","item":"default"}|} )
    ; "blank goal id", snapshot_with ~due:{|{"state":"none"}|} ~goal_id:" "
    ; "due without its date", snapshot_with ~due:{|{"state":"date"}|} ~goal_id:"goal-1"
    ; ( "due with a field it does not take"
      , snapshot_with ~due:{|{"state":"none","date":"2026-09-26"}|} ~goal_id:"goal-1" )
    ; ( "due with a short date"
      , snapshot_with ~due:{|{"state":"date","date":"2026-9-26"}|} ~goal_id:"goal-1" )
    ; "unknown due state", snapshot_with ~due:{|{"state":"soon"}|} ~goal_id:"goal-1"
    ]
;;

let test_an_unreadable_due_keeps_its_text () =
  let text = "the end of the month" in
  let row =
    event
      (E.Snapshot
         { goal_id = "goal-1"
         ; request_id = "req-1"
         ; criterion_revision = "rev-1"
         ; passed_at = now
         ; goal_created_at = now
         ; due = E.Unreadable_due text
         ; title = ""
         ; metric = None
         ; target_value = None
         ; linked_task_ids = []
         })
  in
  Alcotest.check event_testable "round trip" row (ok_or_fail (E.of_line (line_of row)))
;;

let refuses label result = Alcotest.(check bool) label true (Result.is_error result)

let test_a_payout_that_could_not_be_true_is_refused () =
  let alice ?weight ?coefficient ~share ~amount () =
    line ~keeper:"alice" ?weight ?coefficient ~share ~amount ()
  in
  Alcotest.(check bool) "valid" true (Result.is_ok (make_paid two_lines));
  Alcotest.(check bool)
    "shares may add up to less than the total"
    true
    (Result.is_ok (make_paid [ alice ~share:4000 ~amount:4000 () ]));
  Alcotest.(check bool)
    "a zero total with zero shares"
    true
    (Result.is_ok (make_paid ~total:0 [ alice ~share:0 ~amount:0 () ]));
  refuses "no lines" (make_paid []);
  refuses
    "one keeper on two lines"
    (make_paid
       [ alice ~share:5000 ~amount:5000 ()
       ; line ~keeper:"ALICE" ~share:5000 ~amount:5000 ()
       ]);
  refuses "negative weight" (make_paid [ alice ~weight:(-1) ~share:10_000 ~amount:10_000 () ]);
  refuses "coefficient above 1000" (make_paid [ alice ~coefficient:1001 ~share:10_000 ~amount:10_000 () ]);
  refuses "negative coefficient" (make_paid [ alice ~coefficient:(-1) ~share:10_000 ~amount:10_000 () ]);
  refuses "amount above its share" (make_paid [ alice ~share:5000 ~amount:5001 () ]);
  refuses
    "shares above the total"
    (make_paid [ alice ~share:6000 ~amount:6000 (); line ~keeper:"bob" ~share:6000 ~amount:6000 () ]);
  refuses
    "shares that overflow"
    (make_paid
       ~total:max_int
       [ alice ~share:max_int ~amount:0 (); line ~keeper:"bob" ~share:max_int ~amount:0 () ]);
  refuses "negative rate" (make_paid ~deduction:(deduction ~rate:(-1) ()) two_lines);
  refuses "floor above 1000" (make_paid ~deduction:(deduction ~floor:1001 ()) two_lines);
  refuses "blank goal id" (make_paid ~goal_id:" " two_lines);
  refuses "blank request id" (make_paid ~request_id:"" two_lines);
  refuses "blank lane slot" (make_paid ~lane_slot:"" two_lines)
;;

let test_a_payout_row_is_checked_when_it_is_read () =
  (* The row's one line pays 101 out of a share of 100. *)
  refuses
    "amount above its share"
    (E.of_line
       ({|{"kind":"paid","at":"2026-09-29T06:00:00Z","goal_id":"goal-1","request_id":"req-1","grade":"medium","total_milli":10000,"lane_slot":"slot-a",|}
        ^ {|"lines":[{"keeper":"alice","weight":1,"share_milli":100,"coefficient_permille":1000,"amount_milli":101}],|}
        ^ {|"deduction":{"clock":"2026-09-28T06:32:00Z","due":{"state":"none"},"rate_permille":10,"floor_permille":200}}|}))
;;

let test_an_event_that_would_not_read_back_is_not_written () =
  let blank_goal =
    event
      (E.Snapshot
         { goal_id = " "
         ; request_id = "req-1"
         ; criterion_revision = "rev-1"
         ; passed_at = now
         ; goal_created_at = now
         ; due = E.No_due
         ; title = "t"
         ; metric = None
         ; target_value = None
         ; linked_task_ids = []
         })
  in
  refuses "blank goal id" (E.to_line blank_goal)
;;

let () =
  Alcotest.run
    "candle_event"
    [ ( "codec"
      , [ Alcotest.test_case "every kind has a sample" `Quick test_every_kind_has_a_sample
        ; Alcotest.test_case
            "every kind reads back as written"
            `Quick
            test_every_kind_reads_back_as_written
        ; Alcotest.test_case "the row format" `Quick test_the_row_format
        ; Alcotest.test_case
            "an unreadable due keeps its text"
            `Quick
            test_an_unreadable_due_keeps_its_text
        ] )
    ; ( "strict reading"
      , [ Alcotest.test_case
            "the valid lines used below do read"
            `Quick
            test_the_valid_lines_used_below_do_read
        ; Alcotest.test_case
            "a row that is not exactly the schema is refused"
            `Quick
            test_a_row_that_is_not_exactly_the_schema_is_refused
        ; Alcotest.test_case
            "an event that would not read back is not written"
            `Quick
            test_an_event_that_would_not_read_back_is_not_written
        ] )
    ; ( "paid"
      , [ Alcotest.test_case
            "a payout that could not be true is refused"
            `Quick
            test_a_payout_that_could_not_be_true_is_refused
        ; Alcotest.test_case
            "a payout row is checked when it is read"
            `Quick
            test_a_payout_row_is_checked_when_it_is_read
        ] )
    ]
;;
