(** Which pass a confirmation owes a payout for (RFC-goal-candle-ledger 3.1, 3.2). *)

module E = Candle_event

let ok_or_fail = function
  | Ok value -> value
  | Error detail -> Alcotest.failf "%s" detail
;;

let at text = ok_or_fail (Candle_time.of_rfc3339 text)
let pass_text = "2026-09-28T06:32:00Z"

let snapshot ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") ?(passed_at = pass_text) () : E.t =
  { at = at "2026-09-28T06:32:01Z"
  ; body =
      E.Snapshot
        { goal_id
        ; request_id
        ; verification_run_id
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

let owed ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") ?(passed_at = pass_text) () : E.t =
  { at = at "2026-09-29T05:00:01Z"
  ; body =
      E.Payout_owed
        { goal_id
        ; request_id
        ; verification_run_id
        ; passed_at = at passed_at
        ; confirmed_at = at "2026-09-29T05:00:00Z"
        }
  }
;;

let candidates_row ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") ?(keepers = [ "keeper-a" ]) () : E.t =
  { at = at "2026-09-29T05:10:00Z"
  ; body =
      E.Candidates
        { goal_id
        ; request_id
        ; verification_run_id
        ; tasks = []
        ; candidate_task_ids = [ "task-1" ]
        ; candidate_keepers = keepers
        ; candidate_task_keepers = ["task-1", List.nth_opt keepers 0]
        }
  }
;;

let unattributed ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") () : E.t =
  { at = at "2026-09-29T05:20:00Z"
  ; body = E.Unattributed { goal_id; request_id; verification_run_id; reason = E.No_candidates }
  }
;;

let pass = Alcotest.testable (fun ppf time -> Format.pp_print_string ppf (Candle_time.to_rfc3339 time)) Candle_time.equal

let owed_pass ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") ?(passed_at = pass_text) events =
  Candle_payout.owed_pass ~goal_id ~request_id ~verification_run_id ~passed_at events
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
  check_owed "another verifier run in the same second" None
    [ snapshot ~verification_run_id:"other-run" () ];
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
    ];
  check_owed
    "a Goal whose payout is settled"
    None
    [ snapshot ()
    ; owed ()
    ; unattributed ()
    ; snapshot ~request_id:"req-2" ~passed_at:"2026-09-29T01:00:00Z" ()
    ]
;;

let test_another_goals_payout_does_not_block () =
  check_owed
    "goal-2 owes, goal-1 is confirmed"
    (Some (at pass_text))
    [ snapshot (); snapshot ~goal_id:"goal-2" (); owed ~goal_id:"goal-2" () ]
;;

let state_testable =
  Alcotest.testable
    (fun ppf (state : Candle_payout.state) ->
       match state with
       | Candle_payout.No_obligation -> Format.pp_print_string ppf "No_obligation"
       | Candle_payout.Failed w -> Format.fprintf ppf "Failed %s/%s" w.goal_id w.verification_run_id
       | Candle_payout.Settled -> Format.pp_print_string ppf "Settled"
       | Candle_payout.Waiting w -> Format.fprintf ppf "Waiting %s/%s" w.goal_id w.request_id)
    ( = )
;;

let waiting_for ?(goal_id = "goal-1") ?(request_id = "req-1") ?(verification_run_id = "run-1") () : Candle_payout.waiting =
  { goal_id
  ; request_id
  ; verification_run_id
  ; passed_at = at pass_text
  ; confirmed_at = at "2026-09-29T05:00:00Z"
  }
;;

let test_the_state_of_a_goals_payout () =
  let state events = Candle_payout.state ~goal_id:"goal-1" events in
  Alcotest.check state_testable "nothing" Candle_payout.No_obligation (state []);
  Alcotest.check
    state_testable
    "a snapshot alone owes nothing"
    Candle_payout.No_obligation
    (state [ snapshot () ]);
  Alcotest.check
    state_testable
    "an open PayoutOwed waits"
    (Candle_payout.Waiting (waiting_for ()))
    (state [ snapshot (); owed () ]);
  Alcotest.check
    state_testable
    "candidates do not close it"
    (Candle_payout.Waiting (waiting_for ()))
    (state [ snapshot (); owed (); candidates_row () ]);
  Alcotest.check
    state_testable
    "Unattributed settles it"
    Candle_payout.Settled
    (state [ snapshot (); owed (); candidates_row ~keepers:[] (); unattributed () ]);
  Alcotest.check
    state_testable
    "another Goal's Unattributed does not"
    (Candle_payout.Waiting (waiting_for ()))
    (state [ snapshot (); owed (); unattributed ~goal_id:"goal-2" () ])
;;

let test_the_last_open_payout_is_the_one_that_waits () =
  Alcotest.check
    state_testable
    "the later PayoutOwed"
    (Candle_payout.Waiting (waiting_for ~request_id:"req-2" ()))
    (Candle_payout.state
       ~goal_id:"goal-1"
       [ owed (); owed ~request_id:"req-2" () ])
;;

let test_every_waiting_goal_is_listed_once_in_the_order_it_first_owed () =
  let listed =
    Candle_payout.waiting
      [ owed ~goal_id:"goal-b" ()
      ; owed ~goal_id:"goal-a" ()
      ; owed ~goal_id:"goal-b" ~request_id:"req-2" ()
      ; owed ~goal_id:"goal-c" ()
      ; unattributed ~goal_id:"goal-c" ()
      ]
  in
  Alcotest.(check (list (pair string string)))
    "goal-b and goal-a, each once; goal-c is settled"
    [ "goal-b", "req-2"; "goal-a", "req-1" ]
    (List.map (fun (w : Candle_payout.waiting) -> w.goal_id, w.request_id) listed)
;;

let test_a_payout_takes_its_pass_from_the_matching_snapshot () =
  let events =
    [ snapshot ~request_id:"req-0" ~passed_at:"2026-09-27T06:00:00Z" ()
    ; snapshot ()
    ; owed ()
    ]
  in
  (match Candle_payout.pass_of (waiting_for ()) events with
   | Some found ->
     Alcotest.(check (list string)) "linked Tasks" [] found.linked_task_ids;
     Alcotest.check pass "goal_created_at" (at "2026-09-20T01:00:00Z") found.goal_created_at
   | None -> Alcotest.fail "the matching Snapshot was not found");
  Alcotest.(check bool)
    "none for a request that has no Snapshot"
    true
    (Option.is_none (Candle_payout.pass_of (waiting_for ~request_id:"req-9" ()) events))
;;

let test_a_payout_finds_the_candidates_written_for_its_request () =
  let events =
    [ owed (); candidates_row ~request_id:"req-0" ~keepers:[ "old" ] ()
    ; candidates_row ~verification_run_id:"other-run" ~keepers:[ "orphan" ] ()
    ; candidates_row () ]
  in
  (match Candle_payout.candidates_of (waiting_for ()) events with
   | Some found ->
     Alcotest.(check (list string)) "keepers" [ "keeper-a" ] found.candidate_keepers;
     Alcotest.(check (list string)) "tasks" [ "task-1" ] found.candidate_task_ids
   | None -> Alcotest.fail "the Candidates row was not found");
  Alcotest.(check bool)
    "none before they are written"
    true
    (Option.is_none (Candle_payout.candidates_of (waiting_for ()) [ owed () ]))
;;

let done_at time = E.Done { completed_at = at time }

let found ?(assignee = Some "keeper-a") ?(status = done_at "2026-09-25T00:00:00Z") () =
  E.Found { title = "t"; assignee; status }
;;

let decide ?(keepers = [ "keeper-a"; "keeper-b" ]) tasks =
  Candle_payout.decide_candidates
    ~goal_created_at:(at "2026-09-20T01:00:00Z")
    ~confirmed_at:(at "2026-09-29T05:00:00Z")
    ~is_keeper:(fun name -> List.mem name keepers)
    tasks
;;

let ids (decided : Candle_payout.candidates) = decided.candidate_task_ids

let test_a_candidate_task_was_done_between_the_goal_and_the_confirmation () =
  let tasks_done_at time = [ "task-1", found ~status:(done_at time) () ] in
  let check_candidate label expected time =
    Alcotest.(check (list string)) label expected (ids (decide (tasks_done_at time)))
  in
  check_candidate "well inside" [ "task-1" ] "2026-09-25T00:00:00Z";
  check_candidate "the second after the Goal was created" [ "task-1" ] "2026-09-20T01:00:01Z";
  check_candidate "at the Goal's creation" [] "2026-09-20T01:00:00Z";
  check_candidate "before the Goal existed" [] "2026-09-19T00:00:00Z";
  check_candidate "at the confirmation" [ "task-1" ] "2026-09-29T05:00:00Z";
  check_candidate "after the confirmation" [] "2026-09-29T05:00:01Z"
;;

let test_only_a_done_task_found_in_a_store_is_a_candidate () =
  Alcotest.(check (list string))
    "every other status, deleted, done"
    [ "task-7" ]
    (ids
       (decide
          [ "task-1", found ~status:E.Todo ()
          ; "task-2", found ~status:E.Claimed ()
          ; "task-3", found ~status:E.In_progress ()
          ; "task-4", found ~status:E.Awaiting_verification ()
          ; "task-5", found ~status:E.Cancelled ()
          ; "task-6", E.Deleted
          ; "task-7", found ()
          ]))
;;

let test_candidate_keepers_are_the_keepers_among_the_candidate_assignees () =
  let decided =
    decide
      [ "task-1", found ~assignee:(Some "keeper-b") ()
      ; "task-2", found ~assignee:(Some "keeper-a") ()
      ; "task-3", found ~assignee:(Some "keeper-b") ()
      ; "task-4", found ~assignee:(Some "a-human") ()
      ; "task-5", found ~assignee:None ()
      ; "task-6", found ~assignee:(Some "keeper-a") ~status:E.In_progress ()
      ]
  in
  Alcotest.(check (list string))
    "each keeper once, in name order"
    [ "keeper-a"; "keeper-b" ]
    decided.candidate_keepers;
  Alcotest.(check (list string))
    "the candidate Tasks, in the Snapshot's order"
    [ "task-1"; "task-2"; "task-3"; "task-4"; "task-5" ]
    decided.candidate_task_ids
;;

let test_a_keeper_of_a_task_that_is_not_a_candidate_is_not_a_candidate_keeper () =
  Alcotest.(check (list string))
    "keeper-b's Task was done before the Goal"
    [ "keeper-a" ]
    (decide
       [ "task-1", found ~assignee:(Some "keeper-a") ()
       ; "task-2", found ~assignee:(Some "keeper-b") ~status:(done_at "2026-09-01T00:00:00Z") ()
       ])
      .candidate_keepers
;;

let test_no_linked_task_means_no_candidates () =
  let decided = decide [] in
  Alcotest.(check (list string)) "tasks" [] decided.candidate_task_ids;
  Alcotest.(check (list string)) "keepers" [] decided.candidate_keepers
;;

let () =
  Alcotest.run
    "candle_payout"
    [ ( "state"
      , [ Alcotest.test_case "the state of a Goal's payout" `Quick test_the_state_of_a_goals_payout
        ; Alcotest.test_case "the last open payout is the one that waits" `Quick
            test_the_last_open_payout_is_the_one_that_waits
        ; Alcotest.test_case "every waiting goal is listed once in the order it first owed" `Quick
            test_every_waiting_goal_is_listed_once_in_the_order_it_first_owed
        ; Alcotest.test_case "a payout takes its pass from the matching snapshot" `Quick
            test_a_payout_takes_its_pass_from_the_matching_snapshot
        ; Alcotest.test_case "a payout finds the candidates written for its request" `Quick
            test_a_payout_finds_the_candidates_written_for_its_request
        ] )
    ; ( "decide_candidates"
      , [ Alcotest.test_case "a candidate task was done between the goal and the confirmation" `Quick
            test_a_candidate_task_was_done_between_the_goal_and_the_confirmation
        ; Alcotest.test_case "only a done task found in a store is a candidate" `Quick
            test_only_a_done_task_found_in_a_store_is_a_candidate
        ; Alcotest.test_case "candidate keepers are the keepers among the candidate assignees" `Quick
            test_candidate_keepers_are_the_keepers_among_the_candidate_assignees
        ; Alcotest.test_case "a keeper of a task that is not a candidate is not a candidate keeper" `Quick
            test_a_keeper_of_a_task_that_is_not_a_candidate_is_not_a_candidate_keeper
        ; Alcotest.test_case "no linked task means no candidates" `Quick
            test_no_linked_task_means_no_candidates
        ] )
    ; ( "owed_pass"
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
