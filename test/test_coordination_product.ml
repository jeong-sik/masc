(** Tests for Coordination_product — Goal x Task x Board x Reward. *)

open Masc_mcp
module CP = Coordination_product

let done_status =
  Types.Done
    { assignee = "worker"; completed_at = "2026-04-24T00:00:00Z"; notes = Some "ok" }
;;

let claimed_status =
  Types.Claimed { assignee = "worker"; claimed_at = "2026-04-24T00:00:00Z" }
;;

let cancelled_status =
  Types.Cancelled
    { cancelled_by = "operator"
    ; cancelled_at = "2026-04-24T00:00:00Z"
    ; reason = Some "superseded"
    }
;;

let ids ?goal_id ?(task_ids = []) ?(post_ids = []) ?agent_name () : CP.ids =
  { goal_id; task_ids; post_ids; agent_name }
;;

let product
      ?goal
      ?(task = CP.No_task)
      ?(board = CP.Quiet)
      ?(reward = CP.Disabled)
      ?(task_counts = CP.empty_task_counts)
      ?(facts = CP.default_facts)
      ?(evidence = [])
      ?(ids = ids ())
      ()
  : CP.product
  =
  { ids; goal; task; board; reward; task_counts; facts; evidence }
;;

let violation_codes violations = violations |> List.map (fun (v : CP.violation) -> v.code)

let check_has_code code violations =
  Alcotest.(check bool) code true (List.mem code (violation_codes violations))
;;

let test_task_axis_projection () =
  Alcotest.(check string)
    "todo"
    "todo"
    (CP.task_phase_to_string (CP.task_phase_of_status Types.Todo));
  Alcotest.(check string)
    "done"
    "done"
    (CP.task_phase_to_string (CP.task_phase_of_status done_status));
  Alcotest.(check string)
    "empty aggregate"
    "no_task"
    (CP.task_phase_to_string (CP.task_phase_of_counts []));
  Alcotest.(check string)
    "mixed aggregate"
    "mixed"
    (CP.task_phase_to_string (CP.task_phase_of_counts [ done_status; cancelled_status ]))
;;

let test_goal_terminal_open_tasks_violation () =
  let task_counts = CP.task_counts_of_statuses [ claimed_status ] in
  let p =
    product
      ~goal:Goal_phase.Completed
      ~task:CP.Claimed
      ~task_counts
      ~ids:(ids ~goal_id:"goal-1" ~task_ids:[ "task-1" ] ())
      ()
  in
  let violations = CP.check_invariants p in
  check_has_code "goal_terminal_open_tasks" violations
;;

let test_goal_completed_without_done_task_is_advisory () =
  let p =
    product ~goal:Goal_phase.Completed ~task:CP.No_task ~ids:(ids ~goal_id:"goal-1" ()) ()
  in
  let violations = CP.check_invariants p in
  check_has_code "goal_completed_without_done_task" violations;
  match violations with
  | [ { CP.severity = CP.Warn; _ } ] -> ()
  | _ -> Alcotest.fail "expected one warning"
;;

let test_reward_machine_phases () =
  let task_counts = CP.task_counts_of_statuses [ done_status ] in
  let pending =
    CP.reward_phase_of_facts
      ~economy_enabled:true
      ~task_counts
      ~board:CP.Quiet
      ~has_reward_earning:false
      ~has_spend:false
      ~has_penalty:false
  in
  Alcotest.(check string) "pending" "credit_pending" (CP.reward_phase_to_string pending);
  let rewarded =
    CP.reward_phase_of_facts
      ~economy_enabled:true
      ~task_counts
      ~board:CP.Quiet
      ~has_reward_earning:true
      ~has_spend:false
      ~has_penalty:false
  in
  Alcotest.(check string) "rewarded" "rewarded" (CP.reward_phase_to_string rewarded);
  let spent =
    CP.reward_phase_of_facts
      ~economy_enabled:true
      ~task_counts
      ~board:CP.Quiet
      ~has_reward_earning:true
      ~has_spend:true
      ~has_penalty:false
  in
  Alcotest.(check string) "spent" "spent" (CP.reward_phase_to_string spent);
  let penalized =
    CP.reward_phase_of_facts
      ~economy_enabled:true
      ~task_counts
      ~board:CP.Quiet
      ~has_reward_earning:true
      ~has_spend:true
      ~has_penalty:true
  in
  Alcotest.(check string) "penalized" "penalized" (CP.reward_phase_to_string penalized);
  let disabled =
    CP.reward_phase_of_facts
      ~economy_enabled:false
      ~task_counts
      ~board:CP.Quiet
      ~has_reward_earning:true
      ~has_spend:true
      ~has_penalty:true
  in
  Alcotest.(check string) "disabled wins" "disabled" (CP.reward_phase_to_string disabled)
;;

let test_reward_without_evidence_violation () =
  let p =
    product ~reward:CP.Rewarded ~ids:(ids ~goal_id:"goal-1" ~task_ids:[ "task-1" ] ()) ()
  in
  CP.check_invariants p |> check_has_code "reward_without_evidence"
;;

let test_board_degraded_violation () =
  let facts = { CP.default_facts with board_persist_error_count = 1 } in
  let p =
    product
      ~board:CP.Degraded
      ~facts
      ~ids:(ids ~goal_id:"goal-1" ~post_ids:[ "post-1" ] ())
      ()
  in
  CP.check_invariants p |> check_has_code "board_degraded"
;;

let test_snapshot_json () =
  let task_counts = CP.task_counts_of_statuses [ done_status ] in
  let refs = ids ~goal_id:"goal-1" ~task_ids:[ "task-1" ] () in
  let evidence : CP.evidence =
    { source = "telemetry"
    ; kind = "task_completed"
    ; id = Some "task-1"
    ; label = "task completed"
    ; detail = "success=true; duration_ms=42"
    ; timestamp = Some 1.0
    ; refs
    }
  in
  let p =
    product
      ~goal:Goal_phase.Completed
      ~task:CP.Done
      ~task_counts
      ~ids:refs
      ~evidence:[ evidence ]
      ()
  in
  let json = CP.snapshot_to_yojson (CP.snapshot [ p ]) in
  let open Yojson.Safe.Util in
  Alcotest.(check string) "mode" "advisory" (json |> member "mode" |> to_string);
  Alcotest.(check int)
    "products"
    1
    (json |> member "summary" |> member "products" |> to_int);
  Alcotest.(check int)
    "evidence"
    1
    (json |> member "summary" |> member "evidence" |> to_int);
  Alcotest.(check string)
    "evidence source"
    "telemetry"
    (json |> member "products" |> index 0 |> member "evidence" |> index 0 |> member "source"
     |> to_string)
;;

let () =
  Alcotest.run
    "Coordination_product"
    [ "task_axis", [ Alcotest.test_case "projection" `Quick test_task_axis_projection ]
    ; ( "invariants"
      , [ Alcotest.test_case
            "terminal goal with open task"
            `Quick
            test_goal_terminal_open_tasks_violation
        ; Alcotest.test_case
            "completed without evidence warns"
            `Quick
            test_goal_completed_without_done_task_is_advisory
        ; Alcotest.test_case
            "reward without evidence"
            `Quick
            test_reward_without_evidence_violation
        ; Alcotest.test_case "board degraded" `Quick test_board_degraded_violation
        ] )
    ; ( "reward"
      , [ Alcotest.test_case "reward machine phases" `Quick test_reward_machine_phases ] )
    ; "json", [ Alcotest.test_case "snapshot json" `Quick test_snapshot_json ]
    ]
;;
