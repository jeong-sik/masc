(** Money-path cases of RFC-goal-candle-ledger 3.4 and 5 that no other suite
    reaches. A rejection is tested as a minimal pair: the input is admitted
    first, then changed so that one rule alone should refuse it, so a rule that
    stops being checked turns the second half red. Pure: no file, clock or
    server. *)

module A = Candle_appraisal
module E = Candle_event
module P = Candle_payout

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)

(* {1 Weights} *)

let test_weights_follow_the_rules_of_the_rfc () =
  let check label ~keepers ~weight_max weights expected =
    Alcotest.(check bool)
      label
      expected
      (Result.is_ok (A.validate_weights ~keepers ~weight_max weights))
  in
  check "the names are the keepers" ~keepers:[ "a"; "b" ] ~weight_max:10 [ "a", 1; "b", 10 ] true;
  check "zero beside a positive weight" ~keepers:[ "a"; "b" ] ~weight_max:10 [ "a", 0; "b", 1 ] true;
  check "weight_max itself" ~keepers:[ "a" ] ~weight_max:1 [ "a", 1 ] true;
  check "one above weight_max" ~keepers:[ "a"; "b" ] ~weight_max:10 [ "a", 11; "b", 1 ] false;
  check "a negative weight beside a positive one" ~keepers:[ "a"; "b" ] ~weight_max:10 [ "a", -1; "b", 1 ] false;
  check "every weight zero" ~keepers:[ "a"; "b" ] ~weight_max:10 [ "a", 0; "b", 0 ] false;
  check "a keeper with no weight" ~keepers:[ "a"; "b" ] ~weight_max:10 [ "a", 1 ] false;
  check "a weight for a name that is not a keeper" ~keepers:[ "a" ] ~weight_max:10 [ "a", 1; "c", 1 ] false;
  check "the same name twice" ~keepers:[ "a"; "a" ] ~weight_max:10 [ "a", 1; "a", 1 ] false
;;

let test_a_weights_answer_is_read_by_the_same_rules () =
  let goal : A.goal = { title = "Goal"; metric = None; target_value = None } in
  let request = A.Weights { goal; tasks = []; keepers = [ "a"; "b" ]; weight_max = 10 } in
  let reads label expected json =
    Alcotest.(check bool) label expected (Result.is_ok (A.decode request json))
  in
  let answer weights = `Assoc [ "weights", `Assoc weights ] in
  reads "in range" true (answer [ "a", `Int 3; "b", `Int 10 ]);
  reads "above weight_max" false (answer [ "a", `Int 3; "b", `Int 11 ]);
  reads "negative" false (answer [ "a", `Int (-1); "b", `Int 1 ]);
  reads "not an integer" false (answer [ "a", `Float 1.5; "b", `Int 1 ]);
  reads "a number written as text" false (answer [ "a", `String "1"; "b", `Int 1 ]);
  reads "a keeper left out" false (answer [ "a", `Int 1 ]);
  reads
    "a field beside weights"
    false
    (`Assoc [ "weights", `Assoc [ "a", `Int 1; "b", `Int 1 ]; "note", `String "x" ])
;;

(* {1 Settlement admission} *)

let goal_id = "goal-1"
let request_id = "req-1"
let run_id = "run-1"
let passed_at = at "2026-09-28T06:32:00Z"

let waiting : P.waiting =
  { goal_id
  ; request_id
  ; verification_run_id = run_id
  ; passed_at
  ; confirmed_at = at "2026-09-29T05:00:00Z"
  }
;;

let identity : A.identity = { goal_id; request_id; verification_run_id = run_id }
let trace name : A.trace = { run_id = name; slot_id = "slot-1" }

let done_task title assignee =
  E.Found
    { title
    ; assignee = Some assignee
    ; status = E.Done { completed_at = at "2026-09-25T00:00:00Z" }
    }
;;

(* t-a and t-b belong to keepers. t-x belongs to someone without a keeper file, so
   it is a candidate Task but never a recipient. *)
let lookups =
  [ "t-a", done_task "Task A" "keeper-a"
  ; "t-b", done_task "Task B" "keeper-b"
  ; "t-x", done_task "Task X" "outsider"
  ]
;;

let snapshot ~due_date : E.t =
  { at = at "2026-09-28T06:32:01Z"
  ; body =
      E.Snapshot
        { goal_id
        ; request_id
        ; verification_run_id = run_id
        ; criterion_revision = "rev-1"
        ; passed_at
        ; goal_created_at = at "2026-09-20T01:00:00Z"
        ; due_date
        ; title = "Goal"
        ; metric = None
        ; target_value = None
        ; linked_task_ids = [ "t-a"; "t-b"; "t-x" ]
        }
  }
;;

let owed : E.t =
  { at = at "2026-09-29T05:00:01Z"
  ; body =
      E.Payout_owed
        { goal_id
        ; request_id
        ; verification_run_id = run_id
        ; passed_at
        ; confirmed_at = at "2026-09-29T05:00:00Z"
        }
  }
;;

let candidates ?(run = run_id) ?(lookups = lookups) ?(keepers = [ "keeper-a"; "keeper-b" ]) () : E.t =
  { at = at "2026-09-29T05:10:00Z"
  ; body =
      E.Candidates
        { goal_id
        ; request_id
        ; verification_run_id = run
        ; tasks = lookups
        ; candidate_task_ids = [ "t-a"; "t-b"; "t-x" ]
        ; candidate_keepers = keepers
        }
  }
;;

let ledger ?(due_date = Some "2026-09-26") ?(cands = candidates ()) () = [ snapshot ~due_date; owed; cands ]
let relation task decision : A.task_relation = { task_id = task; relation = decision; trace = trace ("relation-" ^ task) }
let related = [ relation "t-a" A.Related; relation "t-b" A.Related; relation "t-x" A.Related ]
let unrelated = List.map (fun task -> relation task A.Unrelated) [ "t-a"; "t-b"; "t-x" ]

let paid ?(identity = identity) ?(relations = related) weights =
  E.Paid
    (ok_or_fail
       (Candle_payment.make
          ~identity
          ~grade:Candle_grade.Medium
          ~total_milli:3000
          ~grade_trace:(trace "grade-run")
          ~relations
          ~weights_trace:(trace "weights-run")
          ~weight_max:10
          ~deduction_rate:10
          ~deduction_floor:200
          ~overdue_hours:30
          ~weights))
;;

let attribution relations : E.attribution =
  { grade = Candle_grade.Medium; grade_trace = trace "grade-run"; relations }
;;

let unattributed reason = E.Unattributed { goal_id; request_id; verification_run_id = run_id; reason }

let check_admission label expected ledger body =
  Alcotest.(check bool) label expected (Result.is_ok (P.validate_settlement waiting ledger body))
;;

let both_recipients = [ "keeper-a", 2; "keeper-b", 1 ]

let test_a_paid_row_is_admitted_only_for_the_related_candidate_keepers () =
  check_admission "the related keepers, each once" true (ledger ()) (paid both_recipients);
  check_admission "no Candidates row" false [ snapshot ~due_date:None; owed ] (paid both_recipients);
  check_admission
    "Candidates of another verifier run only"
    false
    (ledger ~cands:(candidates ~run:"other-run" ()) ())
    (paid both_recipients);
  check_admission
    "a Paid row of another verifier run"
    false
    (ledger ())
    (paid ~identity:{ identity with verification_run_id = "other-run" } both_recipients);
  check_admission
    "a candidate Task left without a decision"
    false
    (ledger ())
    (paid ~relations:[ relation "t-a" A.Related; relation "t-b" A.Related ] both_recipients);
  check_admission
    "a decision for a Task that is no candidate"
    false
    (ledger ())
    (paid ~relations:(related @ [ relation "t-z" A.Related ]) both_recipients);
  (* With t-a gone, the keeper of t-b is the only recipient the other rules would
     admit, so only the missing-row rule refuses this. *)
  check_admission
    "a candidate Task whose row says it is gone"
    false
    (ledger ~cands:(candidates ~lookups:(("t-a", E.Deleted) :: List.tl lookups) ()) ())
    (paid [ "keeper-b", 1 ]);
  (* keeper-b is not among the candidate keepers here, so with the membership rule
     alone this row would be admitted for keeper-a. *)
  check_admission
    "a Task whose assignee is not a candidate keeper"
    true
    (ledger ~cands:(candidates ~keepers:[ "keeper-a" ] ()) ())
    (paid [ "keeper-a", 2 ]);
  check_admission
    "the same Task's assignee named as a recipient anyway"
    false
    (ledger ~cands:(candidates ~keepers:[ "keeper-a" ] ()) ())
    (paid both_recipients);
  check_admission "an outsider named as a recipient" false (ledger ()) (paid [ "keeper-a", 2; "outsider", 1 ]);
  check_admission "no decision says related" false (ledger ()) (paid ~relations:unrelated both_recipients)
;;

let test_nobody_to_pay_is_admitted_only_when_the_decisions_say_so () =
  check_admission
    "no candidate keeper"
    true
    (ledger ~cands:(candidates ~keepers:[] ()) ())
    (unattributed E.No_candidates);
  check_admission "candidate keepers exist" false (ledger ()) (unattributed E.No_candidates);
  check_admission "all unrelated" true (ledger ()) (unattributed (E.All_unrelated (attribution unrelated)));
  check_admission
    "all unrelated, but a Task of an outsider is related"
    false
    (ledger ())
    (unattributed
       (E.All_unrelated
          (attribution [ relation "t-a" A.Unrelated; relation "t-b" A.Unrelated; relation "t-x" A.Related ])));
  check_admission
    "all unrelated, but a keeper's Task is related"
    false
    (ledger ())
    (unattributed
       (E.All_unrelated
          (attribution [ relation "t-a" A.Related; relation "t-b" A.Unrelated; relation "t-x" A.Unrelated ])));
  let outsider_only =
    [ relation "t-a" A.Unrelated; relation "t-b" A.Unrelated; relation "t-x" A.Related ]
  in
  check_admission
    "only an outsider's Task is related"
    true
    (ledger ())
    (unattributed (E.No_related_keepers (attribution outsider_only)));
  check_admission
    "no related keeper, but nothing is related"
    false
    (ledger ())
    (unattributed (E.No_related_keepers (attribution unrelated)));
  check_admission
    "no related keeper, but a keeper's Task is related"
    false
    (ledger ())
    (unattributed
       (E.No_related_keepers
          (attribution [ relation "t-a" A.Related; relation "t-b" A.Unrelated; relation "t-x" A.Related ])))
;;

let test_a_failed_payout_names_the_due_date_the_snapshot_holds () =
  let failed due_date = E.Payout_failed { goal_id; request_id; verification_run_id = run_id; due_date } in
  check_admission "the Snapshot's own text" true (ledger ~due_date:(Some "2026-9-26") ()) (failed "2026-9-26");
  check_admission "a different text" false (ledger ~due_date:(Some "2026-09-26") ()) (failed "2026-9-26")
;;

(* {1 Balance} *)

let credit_payment ~goal ~request ~run amount =
  ok_or_fail
    (Candle_payment.make
       ~identity:{ A.goal_id = goal; request_id = request; verification_run_id = run }
       ~grade:Candle_grade.Trivial
       ~total_milli:amount
       ~grade_trace:(trace "grade-run")
       ~relations:[ relation "t" A.Related ]
       ~weights_trace:(trace "weights-run")
       ~weight_max:1
       ~deduction_rate:0
       ~deduction_floor:1000
       ~overdue_hours:0
       ~weights:[ "keeper", 1 ])
;;

let credited state payment =
  match Candle_balance.credit state payment with
  | Ok next -> next
  | Error error -> Alcotest.failf "%s" (Candle_balance.error_to_string error)
;;

let test_a_goal_is_credited_once_whatever_its_request_and_run () =
  let first = credited Candle_balance.empty (credit_payment ~goal:"g" ~request:"r1" ~run:"v1" 1000) in
  match Candle_balance.credit first (credit_payment ~goal:"g" ~request:"r2" ~run:"v2" 500) with
  | Error (Candle_balance.Duplicate_payment "g") ->
    Alcotest.(check int) "the balance is unchanged" 1000 (Candle_balance.balance first ~keeper:"keeper")
  | Ok _ | Error _ -> Alcotest.fail "a second payment for the Goal was accepted"
;;

let test_the_last_milli_candle_that_fits_is_credited_and_the_next_is_not () =
  let unit_amount = max_int / 1000 in
  let headroom = max_int - (1000 * unit_amount) in
  let full =
    List.fold_left
      (fun state i -> credited state (credit_payment ~goal:(string_of_int i) ~request:"r" ~run:"v" unit_amount))
      Candle_balance.empty
      (List.init 1000 Fun.id)
  in
  let exact = credited full (credit_payment ~goal:"last" ~request:"r" ~run:"v" headroom) in
  Alcotest.(check int) "the balance reaches max_int" max_int (Candle_balance.balance exact ~keeper:"keeper");
  match Candle_balance.credit full (credit_payment ~goal:"over" ~request:"r" ~run:"v" (headroom + 1)) with
  | Error (Candle_balance.Balance_overflow "keeper") -> ()
  | Ok _ | Error _ -> Alcotest.fail "one milli-candle past max_int was accepted"
;;

let () =
  Alcotest.run
    "candle_money_path"
    [ ( "weights"
      , [ Alcotest.test_case "the rules of the RFC" `Quick test_weights_follow_the_rules_of_the_rfc
        ; Alcotest.test_case "an answer is read by the same rules" `Quick test_a_weights_answer_is_read_by_the_same_rules
        ] )
    ; ( "settlement admission"
      , [ Alcotest.test_case
            "a Paid row is admitted only for the related candidate keepers"
            `Quick
            test_a_paid_row_is_admitted_only_for_the_related_candidate_keepers
        ; Alcotest.test_case
            "nobody to pay is admitted only when the decisions say so"
            `Quick
            test_nobody_to_pay_is_admitted_only_when_the_decisions_say_so
        ; Alcotest.test_case
            "a failed payout names the due date the Snapshot holds"
            `Quick
            test_a_failed_payout_names_the_due_date_the_snapshot_holds
        ] )
    ; ( "balance"
      , [ Alcotest.test_case
            "a Goal is credited once whatever its request and run"
            `Quick
            test_a_goal_is_credited_once_whatever_its_request_and_run
        ; Alcotest.test_case
            "the last milli-candle that fits is credited and the next is not"
            `Quick
            test_the_last_milli_candle_that_fits_is_credited_and_the_next_is_not
        ] )
    ]
;;
