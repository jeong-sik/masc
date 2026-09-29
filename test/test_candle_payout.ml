(** Which pass a confirmation owes a payout for (RFC-goal-candle-ledger 3.1, 3.2). *)

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)
let pass_text = "2026-09-28T06:32:00Z"

let snapshot ?(goal_id = "goal-1") ?(request_id = "req-1") ?(passed_at = pass_text) () : E.t =
  { at = at "2026-09-28T06:32:01Z"
  ; body =
      E.Snapshot
        { goal_id
        ; request_id
        ; criterion_revision = "rev-1"
        ; passed_at = at passed_at
        ; goal_created_at = at "2026-09-20T01:00:00Z"
        ; due_date = None
        ; title = "Ship the ledger"
        ; metric = None
        ; target_value = None
        ; linked_task_ids = []
        }
  }
;;

let owed ?(goal_id = "goal-1") ?(request_id = "req-1") ?(passed_at = pass_text) () : E.t =
  { at = at "2026-09-29T05:00:01Z"
  ; body =
      E.Payout_owed
        { goal_id
        ; request_id
        ; passed_at = at passed_at
        ; confirmed_at = at "2026-09-29T05:00:00Z"
        }
  }
;;

let pass = Alcotest.testable (fun ppf time -> Format.pp_print_string ppf (Candle_time.to_rfc3339 time)) Candle_time.equal

let owed_pass ?(goal_id = "goal-1") ?(request_id = "req-1") ?(passed_at = pass_text) events =
  Candle_payout.owed_pass ~goal_id ~request_id ~passed_at events
;;

let check_owed label expected events =
  Alcotest.check (Alcotest.option pass) label expected (owed_pass events)
;;

let test_a_confirmed_pass_with_a_snapshot_is_owed () =
  check_owed "the pass the Snapshot wrote" (Some (at pass_text)) [ snapshot () ]
;;

let test_no_snapshot_owes_nothing () =
  check_owed "an empty ledger" None [];
  check_owed "another Goal's Snapshot" None [ snapshot ~goal_id:"goal-2" () ];
  check_owed "another request's Snapshot" None [ snapshot ~request_id:"req-2" () ];
  check_owed
    "the same request passed at another time"
    None
    [ snapshot ~passed_at:"2026-09-28T06:32:01Z" () ]
;;

let test_the_pass_time_is_compared_in_the_ledgers_form () =
  Alcotest.check
    (Alcotest.option pass)
    "the same instant written with an offset"
    None
    (owed_pass ~passed_at:"2026-09-28T15:32:00+09:00" [ snapshot () ])
;;

let test_the_matching_snapshot_is_found_among_others () =
  check_owed
    "before and after it, and a copy of it"
    (Some (at pass_text))
    [ snapshot ~request_id:"req-0" ~passed_at:"2026-09-27T06:00:00Z" ()
    ; snapshot ()
    ; snapshot ~goal_id:"goal-2" ()
    ; snapshot ()
    ; snapshot ~request_id:"req-2" ~passed_at:"2026-09-29T01:00:00Z" ()
    ]
;;

let test_a_goal_that_owes_already_owes_no_more () =
  check_owed "the same pass" None [ snapshot (); owed () ];
  check_owed
    "a later pass of the same Goal"
    None
    [ snapshot ()
    ; owed ()
    ; snapshot ~request_id:"req-2" ~passed_at:"2026-09-29T01:00:00Z" ()
    ]
;;

let test_another_goals_payout_does_not_block () =
  check_owed
    "goal-2 owes, goal-1 is confirmed"
    (Some (at pass_text))
    [ snapshot (); snapshot ~goal_id:"goal-2" (); owed ~goal_id:"goal-2" () ]
;;

let () =
  Alcotest.run
    "candle_payout"
    [ ( "owed_pass"
      , [ Alcotest.test_case "a confirmed pass with a snapshot is owed" `Quick
            test_a_confirmed_pass_with_a_snapshot_is_owed
        ; Alcotest.test_case "no snapshot owes nothing" `Quick test_no_snapshot_owes_nothing
        ; Alcotest.test_case "the pass time is compared in the ledger's form" `Quick
            test_the_pass_time_is_compared_in_the_ledgers_form
        ; Alcotest.test_case "the matching snapshot is found among others" `Quick
            test_the_matching_snapshot_is_found_among_others
        ; Alcotest.test_case "a goal that owes already owes no more" `Quick
            test_a_goal_that_owes_already_owes_no_more
        ; Alcotest.test_case "another goal's payout does not block" `Quick
            test_another_goals_payout_does_not_block
        ] )
    ]
;;
