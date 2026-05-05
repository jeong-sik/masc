module Types = Masc_domain

(** Tests for Coordination_product — Goal x Task x Board x Reward. *)

open Masc_mcp
module CP = Coordination_product
module CPS = Coordination_product_snapshot

let done_status =
  Masc_domain.Done
    { assignee = "worker"; completed_at = "2026-04-24T00:00:00Z"; notes = Some "ok" }
;;

let claimed_status =
  Masc_domain.Claimed { assignee = "worker"; claimed_at = "2026-04-24T00:00:00Z" }
;;

let cancelled_status =
  Masc_domain.Cancelled
    { cancelled_by = "operator"
    ; cancelled_at = "2026-04-24T00:00:00Z"
    ; reason = Some "superseded"
    }
;;

let ids ?goal_id ?(task_ids = []) ?(post_ids = []) ?agent_name () : CP.ids =
  { goal_id; task_ids; post_ids; agent_name }
;;

let task ?goal_id ?(task_status = Masc_domain.Todo) ~id ~title () : Masc_domain.task =
  { id
  ; title
  ; description = ""
  ; task_status
  ; priority = 3
  ; files = []
  ; created_at = "2026-04-24T00:00:00Z"
  ; created_by = None
  ; worktree = None
  ; goal_id
  ; stage = None
  ; contract = None
  ; handoff_context = None
  ; cycle_count = 0
  ; do_not_reclaim_reason = None
  }
;;

let goal ?(phase = Goal_phase.Executing) ~id ~title () : Goal_store.goal =
  { id
  ; horizon = Goal_store.Short
  ; title
  ; metric = None
  ; target_value = None
  ; due_date = None
  ; priority = 3
  ; status = Goal_store.Active
  ; phase
  ; verifier_policy = None
  ; require_completion_approval = false
  ; active_verification_request_id = None
  ; parent_goal_id = None
  ; last_review_note = None
  ; last_review_at = None
  ; created_at = "2026-04-24T00:00:00Z"
  ; updated_at = "2026-04-24T00:00:01Z"
  }
;;

let post_id value =
  match Board.Post_id.of_string value with
  | Ok id -> id
  | Error err -> Alcotest.failf "invalid post id: %s" (Board.show_board_error err)
;;

let agent_id value =
  match Board.Agent_id.of_string value with
  | Ok id -> id
  | Error err -> Alcotest.failf "invalid agent id: %s" (Board.show_board_error err)
;;

let post ?(updated_at = 2.0) ~id ~title ~meta_json () : Board.post =
  { id = post_id id
  ; author = agent_id "worker"
  ; title
  ; body = "body"
  ; content = "content"
  ; post_kind = Board.Automation_post
  ; meta_json = Some meta_json
  ; visibility = Board.Internal
  ; created_at = 1.0
  ; updated_at
  ; expires_at = 0.0
  ; votes_up = 0
  ; votes_down = 0
  ; reply_count = 0
  ; hearth = None
  ; thread_id = None
  }
;;

let transaction ?(timestamp = 3.0) ~id ~task_id () : Agent_economy.transaction =
  { id
  ; agent_name = "worker"
  ; kind = Agent_economy.Earn_task_done
  ; amount = 1.0
  ; balance_after = 11.0
  ; reason = "done"
  ; counterparty = "system"
  ; metadata = `Assoc [ CP.Ref_key.task_id, `String task_id ]
  ; timestamp
  }
;;

let telemetry ?(timestamp = 4.0) ~task_id () : Telemetry_eio.event_record =
  { timestamp
  ; event = Telemetry_eio.Task_completed { task_id; duration_ms = 42; success = true }
  }
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
    (CP.task_phase_to_string (CP.task_phase_of_status Masc_domain.Todo));
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

let test_observation_principles_are_stable () =
  Alcotest.(check (list string))
    "principles"
    [ "observable_updates"; "deterministic_convergence"; "monotonic_progress" ]
    (List.map CP.observation_principle_to_string CP.observation_driven_principles)
;;

let test_visible_claim_queue_is_deterministic () =
  let tasks =
    [ task ~id:"claimed" ~title:"Claimed" ~task_status:claimed_status ()
    ; task ~id:"later" ~title:"Later" ()
    ; task ~id:"earlier" ~title:"Earlier" ()
    ]
  in
  let tasks =
    List.map
      (fun (task : Masc_domain.task) ->
         if String.equal task.id "later"
         then { task with priority = 2; created_at = "2026-04-24T02:00:00Z" }
         else if String.equal task.id "earlier"
         then { task with priority = 1; created_at = "2026-04-24T01:00:00Z" }
         else task)
      tasks
  in
  let queue = CP.visible_claim_queue tasks in
  Alcotest.(check (list string))
    "queue"
    [ "earlier"; "later" ]
    (List.map (fun (entry : CP.turn_queue_entry) -> entry.task_id) queue)
;;

let test_duplicate_active_claim_violation () =
  let tasks =
    [ task
        ~id:"task-dup"
        ~title:"First owner"
        ~task_status:
          (Masc_domain.Claimed { assignee = "worker-a"; claimed_at = "2026-04-24T00:00:00Z" })
        ()
    ; task
        ~id:"task-dup"
        ~title:"Second owner"
        ~task_status:
          (Masc_domain.InProgress { assignee = "worker-b"; started_at = "2026-04-24T00:01:00Z" })
        ()
    ; task ~id:"task-open" ~title:"Open" ()
    ]
  in
  let duplicates = CP.duplicate_active_claims tasks in
  (match duplicates with
   | [ { CP.task_id = "task-dup"; owners } ] ->
     Alcotest.(check (list string)) "owners" [ "worker-a"; "worker-b" ] owners
   | _ -> Alcotest.fail "expected one duplicate active claim");
  let violations = CP.observation_driven_violations tasks in
  check_has_code "duplicate_active_claim_owners" violations
;;

let test_goal_linkage_prefers_structured_goal_id () =
  let explicit =
    task ~id:"task-1" ~title:"Implement product FSM" ~goal_id:"goal-1" ()
  in
  let legacy =
    task ~id:"task-2" ~title:"[goal:goal-1] legacy marker" ()
  in
  let explicit_other_with_legacy_marker =
    task
      ~id:"task-3"
      ~title:"[goal:goal-1] stale legacy marker"
      ~goal_id:"goal-2"
      ()
  in
  Alcotest.(check bool)
    "explicit goal_id matches"
    true
    (Convergence.task_has_goal_id ~goal_id:"goal-1" explicit);
  Alcotest.(check bool)
    "legacy marker does not satisfy structured matcher"
    false
    (Convergence.task_has_goal_id ~goal_id:"goal-1" legacy);
  Alcotest.(check bool)
    "legacy matcher remains backward compatible"
    true
    (Convergence.task_matches_goal ~goal_id:"goal-1" legacy);
  Alcotest.(check bool)
    "structured goal_id wins over stale title marker"
    false
    (Convergence.task_matches_goal ~goal_id:"goal-1" explicit_other_with_legacy_marker)
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
    { source = CP.Source_telemetry
    ; kind = CP.Evidence_telemetry_task_completed
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

let test_projection_is_deterministic_from_captured_state () =
  let goal_a = goal ~id:"goal-a" ~title:"A" () in
  let goal_b = goal ~id:"goal-b" ~title:"B" () in
  let task_a =
    task ~goal_id:"goal-a" ~id:"task-a" ~title:"A task" ~task_status:done_status ()
  in
  let task_b = task ~goal_id:"goal-b" ~id:"task-b" ~title:"B task" () in
  let orphan = task ~id:"task-orphan" ~title:"Orphan task" () in
  let post_a =
    post
      ~id:"post-a"
      ~title:"A signal"
      ~meta_json:(`Assoc [ CP.Ref_key.task_id, `String "task-a" ])
      ()
  in
  let txn_a = transaction ~id:"txn-a" ~task_id:"task-a" () in
  let telemetry_a = telemetry ~task_id:"task-a" () in
  let left : CPS.observed_state =
    { goals = [ goal_b; goal_a ]
    ; tasks = [ orphan; task_b; task_a ]
    ; posts = [ post_a ]
    ; transactions = [ txn_a ]
    ; telemetry_events = [ telemetry_a ]
    ; persist_errors = 0
    ; economy_enabled = true
    }
  in
  let right =
    { left with
      goals = List.rev left.goals
    ; tasks = List.rev left.tasks
    ; posts = List.rev left.posts
    ; transactions = List.rev left.transactions
    ; telemetry_events = List.rev left.telemetry_events
    }
  in
  let left_json = left |> CPS.project |> CP.snapshot_to_yojson |> Yojson.Safe.to_string in
  let right_json = right |> CPS.project |> CP.snapshot_to_yojson |> Yojson.Safe.to_string in
  Alcotest.(check string) "projection ignores capture order" left_json right_json;
  let disabled =
    { left with economy_enabled = false }
    |> CPS.project
    |> CP.snapshot_to_yojson
  in
  let open Yojson.Safe.Util in
  Alcotest.(check string)
    "captured economy flag controls reward deterministically"
    "disabled"
    (disabled |> member "products" |> index 0 |> member "reward" |> to_string)
;;

let () =
  Alcotest.run
    "Coordination_product"
    [ ( "task_axis"
      , [ Alcotest.test_case "projection" `Quick test_task_axis_projection
        ; Alcotest.test_case
            "observation principles"
            `Quick
            test_observation_principles_are_stable
        ; Alcotest.test_case
            "visible claim queue"
            `Quick
            test_visible_claim_queue_is_deterministic
        ; Alcotest.test_case
            "duplicate active claim owners"
            `Quick
            test_duplicate_active_claim_violation
        ] )
    ; ( "goal_linkage"
      , [ Alcotest.test_case
            "structured goal_id matcher"
            `Quick
            test_goal_linkage_prefers_structured_goal_id
        ] )
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
    ; ( "json"
      , [ Alcotest.test_case "snapshot json" `Quick test_snapshot_json
        ; Alcotest.test_case
            "captured-state projection is deterministic"
            `Quick
            test_projection_is_deterministic_from_captured_state
        ] )
    ]
;;
