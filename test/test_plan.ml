(** Unit tests for Plan module (v0.77.0). *)

open Alcotest
open Agent_sdk

(* ── Basic creation ──────────────────────────────── *)

let test_create () =
  let p = Plan.create ~goal:"deploy v2" ~planner:"alice" () in
  check string "goal" "deploy v2" (Plan.goal p);
  check string "planner" "alice" (Plan.planner p);
  check int "no steps" 0 (Plan.step_count p);
  match Plan.status p with
  | Planning -> ()
  | _ -> fail "expected Planning"
;;

let test_add_steps () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  let p = Plan.add_step p ~id:"s1" ~description:"step one" () in
  let p = Plan.add_step p ~id:"s2" ~description:"step two" () in
  check int "2 steps" 2 (Plan.step_count p);
  let steps = Plan.steps p in
  check string "s1 id" "s1" (List.hd steps).id;
  check string "s2 id" "s2" (List.nth steps 1).id
;;

(* ── Step lifecycle ──────────────────────────────── *)

let test_step_lifecycle () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p -> Plan.add_step p ~id:"s1" ~description:"do thing" () |> Plan.start
  in
  (* start_step *)
  let p = Plan.start_step p "s1" in
  (match Plan.find_step p "s1" with
   | Some { status = Running; _ } -> ()
   | _ -> fail "expected Running");
  (* complete_step *)
  let p = Plan.complete_step p "s1" ~result:(`String "done") in
  match Plan.find_step p "s1" with
  | Some { status = Done; result = Some (`String "done"); _ } -> ()
  | _ -> fail "expected Done with result"
;;

let test_fail_step () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"risky" ()
    |> Plan.start
    |> fun p -> Plan.start_step p "s1" |> fun p -> Plan.fail_step p "s1" ~reason:"timeout"
  in
  match Plan.find_step p "s1" with
  | Some { status = Failed "timeout"; _ } -> ()
  | _ -> fail "expected Failed(timeout)"
;;

let test_skip_step () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"optional" () |> fun p -> Plan.skip_step p "s1"
  in
  match Plan.find_step p "s1" with
  | Some { status = Skipped; _ } -> ()
  | _ -> fail "expected Skipped"
;;

(* ── Progress tracking ───────────────────────────── *)

let test_progress () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s2" ~description:"b" ()
    |> fun p ->
    Plan.add_step p ~id:"s3" ~description:"c" ()
    |> fun p -> Plan.add_step p ~id:"s4" ~description:"d" ()
  in
  let eps = 0.01 in
  check (float eps) "0% progress" 0.0 (Plan.progress p);
  let p = Plan.complete_step p "s1" ~result:`Null in
  check (float eps) "25% progress" 0.25 (Plan.progress p);
  let p = Plan.skip_step p "s2" in
  check (float eps) "50% progress" 0.5 (Plan.progress p);
  let p = Plan.complete_step p "s3" ~result:`Null in
  let p = Plan.complete_step p "s4" ~result:`Null in
  check (float eps) "100% progress" 1.0 (Plan.progress p)
;;

let test_progress_empty () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  let eps = 0.01 in
  check (float eps) "empty = 100%" 1.0 (Plan.progress p)
;;

(* ── Current step ────────────────────────────────── *)

let test_current_step_running () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s2" ~description:"b" () |> fun p -> Plan.start_step p "s2"
  in
  match Plan.current_step p with
  | Some { id = "s2"; _ } -> ()
  | _ -> fail "expected s2 as current (running)"
;;

let test_current_step_pending () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"a" ()
    |> fun p -> Plan.add_step p ~id:"s2" ~description:"b" ()
  in
  match Plan.current_step p with
  | Some { id = "s1"; _ } -> ()
  | _ -> fail "expected s1 as current (first pending)"
;;

let test_current_step_none () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"a" ()
    |> fun p -> Plan.complete_step p "s1" ~result:`Null
  in
  match Plan.current_step p with
  | None -> ()
  | Some _ -> fail "expected None (all done)"
;;

(* ── Dependencies ────────────────────────────────── *)

let test_deps_satisfied () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"fetch" ()
    |> fun p -> Plan.add_step p ~id:"s2" ~description:"process" ~depends_on:[ "s1" ] ()
  in
  check bool "s2 deps not met" false (Plan.deps_satisfied p "s2");
  let p = Plan.complete_step p "s1" ~result:`Null in
  check bool "s2 deps met" true (Plan.deps_satisfied p "s2")
;;

let test_deps_multi () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"a" ~description:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"b" ~description:"b" ()
    |> fun p -> Plan.add_step p ~id:"c" ~description:"c" ~depends_on:[ "a"; "b" ] ()
  in
  check bool "c deps not met" false (Plan.deps_satisfied p "c");
  let p = Plan.complete_step p "a" ~result:`Null in
  check bool "c still not met (b pending)" false (Plan.deps_satisfied p "c");
  let p = Plan.complete_step p "b" ~result:`Null in
  check bool "c deps met" true (Plan.deps_satisfied p "c")
;;

let test_deps_nonexistent () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  check bool "nonexistent step" false (Plan.deps_satisfied p "nope")
;;

(* ── Re-planning ─────────────────────────────────── *)

let test_replan () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> fun p ->
    Plan.add_step p ~id:"s1" ~description:"done" ()
    |> fun p ->
    Plan.add_step p ~id:"s2" ~description:"will replace" ()
    |> fun p ->
    Plan.add_step p ~id:"s3" ~description:"will replace too" ()
    |> fun p -> Plan.complete_step p "s1" ~result:`Null
  in
  let new_steps : Plan.step list =
    [ { id = "s4"
      ; description = "new plan"
      ; status = Pending
      ; result = None
      ; depends_on = []
      }
    ]
  in
  let p = Plan.replan p ~new_steps in
  (match Plan.status p with
   | Replanning -> ()
   | _ -> fail "expected Replanning");
  check int "2 steps (1 done + 1 new)" 2 (Plan.step_count p);
  (* s1 preserved, s2/s3 replaced *)
  check bool "s1 kept" true (Option.is_some (Plan.find_step p "s1"));
  check bool "s2 removed" true (Option.is_none (Plan.find_step p "s2"));
  check bool "s4 added" true (Option.is_some (Plan.find_step p "s4"))
;;

(* ── Lifecycle status ────────────────────────────── *)

let test_is_done () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  check bool "planning not done" false (Plan.is_done p);
  let p = Plan.finish p in
  check bool "completed is done" true (Plan.is_done p);
  let p2 = Plan.create ~goal:"g" ~planner:"a" () in
  let p2 = Plan.abandon p2 ~reason:"cancelled" in
  check bool "abandoned is done" true (Plan.is_done p2)
;;

(* ── Serialization round-trip ────────────────────── *)

let test_serialization_empty () =
  let p = Plan.create ~goal:"test goal" ~planner:"bot" () in
  let json = Plan.to_json p in
  match Plan.of_json json with
  | Ok p2 ->
    check string "goal preserved" "test goal" (Plan.goal p2);
    check string "planner preserved" "bot" (Plan.planner p2);
    check int "no steps" 0 (Plan.step_count p2)
  | Error e -> fail e
;;

let test_serialization_with_steps () =
  let p =
    Plan.create ~goal:"deploy" ~planner:"ci" ()
    |> fun p ->
    Plan.add_step p ~id:"build" ~description:"build image" ()
    |> fun p ->
    Plan.add_step p ~id:"test" ~description:"run tests" ~depends_on:[ "build" ] ()
    |> fun p ->
    Plan.add_step
      p
      ~id:"deploy"
      ~description:"push to prod"
      ~depends_on:[ "build"; "test" ]
      ()
    |> Plan.start
    |> fun p ->
    Plan.start_step p "build"
    |> fun p ->
    Plan.complete_step p "build" ~result:(`String "image:v2")
    |> fun p -> Plan.fail_step p "test" ~reason:"flaky"
  in
  let json = Plan.to_json p in
  match Plan.of_json json with
  | Ok p2 ->
    check string "goal" "deploy" (Plan.goal p2);
    check int "3 steps" 3 (Plan.step_count p2);
    (match Plan.find_step p2 "build" with
     | Some { status = Done; result = Some (`String "image:v2"); _ } -> ()
     | _ -> fail "build step mismatch");
    (match Plan.find_step p2 "test" with
     | Some { status = Failed "flaky"; _ } -> ()
     | _ -> fail "test step mismatch");
    (match Plan.find_step p2 "deploy" with
     | Some { status = Pending; depends_on; _ } ->
       check (list string) "deploy deps" [ "build"; "test" ] depends_on
     | _ -> fail "deploy step mismatch")
  | Error e -> fail e
;;

let test_serialization_abandoned () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" () |> fun p -> Plan.abandon p ~reason:"budget cut"
  in
  let json = Plan.to_json p in
  match Plan.of_json json with
  | Ok p2 ->
    (match Plan.status p2 with
     | Abandoned "budget cut" -> ()
     | _ -> fail "expected Abandoned")
  | Error e -> fail e
;;

let test_deserialization_invalid () =
  match Plan.of_json (`String "garbage") with
  | Error _ -> ()
  | Ok _ -> fail "expected error"
;;

(* ── String conversions ──────────────────────────── *)

let test_status_strings () =
  check string "Pending" "Pending" (Plan.step_status_to_string Pending);
  check string "Running" "Running" (Plan.step_status_to_string Running);
  check string "Done" "Done" (Plan.step_status_to_string Done);
  check string "Failed" "Failed(x)" (Plan.step_status_to_string (Failed "x"));
  check string "Skipped" "Skipped" (Plan.step_status_to_string Skipped);
  check string "Planning" "Planning" (Plan.plan_status_to_string Planning);
  check string "Executing" "Executing" (Plan.plan_status_to_string Executing);
  check string "Replanning" "Replanning" (Plan.plan_status_to_string Replanning);
  check string "Completed" "Completed" (Plan.plan_status_to_string Completed);
  check string "Abandoned" "Abandoned(x)" (Plan.plan_status_to_string (Abandoned "x"))
;;

(* ── Transition guards ──────────────────────────────── *)

let test_valid_planning_to_executing () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  match Plan.transition_plan p Executing with
  | Ok p2 ->
    (match Plan.status p2 with
     | Executing -> ()
     | _ -> fail "expected Executing")
  | Error _ -> fail "expected Ok"
;;

let test_valid_executing_to_replanning () =
  let p = Plan.create ~goal:"g" ~planner:"a" () |> Plan.start in
  match Plan.transition_plan p Replanning with
  | Ok p2 ->
    (match Plan.status p2 with
     | Replanning -> ()
     | _ -> fail "expected Replanning")
  | Error _ -> fail "expected Ok"
;;

let test_valid_executing_to_completed () =
  let p = Plan.create ~goal:"g" ~planner:"a" () |> Plan.start in
  match Plan.transition_plan p Completed with
  | Ok p2 ->
    (match Plan.status p2 with
     | Completed -> ()
     | _ -> fail "expected Completed")
  | Error _ -> fail "expected Ok"
;;

let test_valid_replanning_to_executing () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> Plan.start
    |> fun p -> Plan.replan p ~new_steps:[]
  in
  match Plan.transition_plan p Executing with
  | Ok p2 ->
    (match Plan.status p2 with
     | Executing -> ()
     | _ -> fail "expected Executing")
  | Error _ -> fail "expected Ok"
;;

let test_valid_abandon_from_planning () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  match Plan.transition_plan p (Abandoned "changed mind") with
  | Ok p2 ->
    (match Plan.status p2 with
     | Abandoned "changed mind" -> ()
     | _ -> fail "expected Abandoned")
  | Error _ -> fail "expected Ok"
;;

let test_valid_abandon_from_executing () =
  let p = Plan.create ~goal:"g" ~planner:"a" () |> Plan.start in
  match Plan.transition_plan p (Abandoned "budget") with
  | Ok p2 ->
    (match Plan.status p2 with
     | Abandoned "budget" -> ()
     | _ -> fail "expected Abandoned")
  | Error _ -> fail "expected Ok"
;;

let test_valid_abandon_from_replanning () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" ()
    |> Plan.start
    |> fun p -> Plan.replan p ~new_steps:[]
  in
  match Plan.transition_plan p (Abandoned "stale") with
  | Ok p2 ->
    (match Plan.status p2 with
     | Abandoned "stale" -> ()
     | _ -> fail "expected Abandoned")
  | Error _ -> fail "expected Ok"
;;

let test_invalid_planning_to_completed () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  match Plan.transition_plan p Completed with
  | Ok _ -> fail "expected Error"
  | Error (InvalidPlanTransition { from_status; to_status }) ->
    (match from_status, to_status with
     | Planning, Completed -> ()
     | _ -> fail "wrong error fields")
  | Error _ -> fail "expected InvalidPlanTransition"
;;

let test_invalid_planning_to_replanning () =
  let p = Plan.create ~goal:"g" ~planner:"a" () in
  match Plan.transition_plan p Replanning with
  | Ok _ -> fail "expected Error"
  | Error (InvalidPlanTransition _) -> ()
  | Error _ -> fail "expected InvalidPlanTransition"
;;

let test_invalid_executing_to_planning () =
  let p = Plan.create ~goal:"g" ~planner:"a" () |> Plan.start in
  match Plan.transition_plan p Planning with
  | Ok _ -> fail "expected Error"
  | Error (InvalidPlanTransition _) -> ()
  | Error _ -> fail "expected InvalidPlanTransition"
;;

let test_terminal_completed_rejects () =
  let p = Plan.create ~goal:"g" ~planner:"a" () |> Plan.start |> Plan.finish in
  match Plan.transition_plan p Executing with
  | Ok _ -> fail "expected Error"
  | Error (PlanAlreadyTerminal { status }) ->
    (match status with
     | Completed -> ()
     | _ -> fail "wrong status")
  | Error _ -> fail "expected PlanAlreadyTerminal"
;;

let test_terminal_abandoned_rejects () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" () |> fun p -> Plan.abandon p ~reason:"done"
  in
  match Plan.transition_plan p Executing with
  | Ok _ -> fail "expected Error"
  | Error (PlanAlreadyTerminal _) -> ()
  | Error _ -> fail "expected PlanAlreadyTerminal"
;;

let test_terminal_abandoned_rejects_abandon () =
  let p =
    Plan.create ~goal:"g" ~planner:"a" () |> fun p -> Plan.abandon p ~reason:"first"
  in
  match Plan.transition_plan p (Abandoned "second") with
  | Ok _ -> fail "expected Error"
  | Error (PlanAlreadyTerminal _) -> ()
  | Error _ -> fail "expected PlanAlreadyTerminal"
;;

let test_is_terminal_status () =
  check bool "Planning not terminal" false (Plan.is_terminal_status Planning);
  check bool "Executing not terminal" false (Plan.is_terminal_status Executing);
  check bool "Replanning not terminal" false (Plan.is_terminal_status Replanning);
  check bool "Completed terminal" true (Plan.is_terminal_status Completed);
  check bool "Abandoned terminal" true (Plan.is_terminal_status (Abandoned "x"))
;;

let test_valid_plan_transitions_exhaustive () =
  check int "Planning has 1" 1 (List.length (Plan.valid_plan_transitions Planning));
  check int "Executing has 2" 2 (List.length (Plan.valid_plan_transitions Executing));
  check int "Replanning has 1" 1 (List.length (Plan.valid_plan_transitions Replanning));
  check int "Completed has 0" 0 (List.length (Plan.valid_plan_transitions Completed));
  check
    int
    "Abandoned has 0"
    0
    (List.length (Plan.valid_plan_transitions (Abandoned "x")))
;;

let test_can_transition_to () =
  check bool "Planning->Executing" true (Plan.can_transition_to Planning Executing);
  check bool "Planning->Completed" false (Plan.can_transition_to Planning Completed);
  check bool "Planning->Abandoned" true (Plan.can_transition_to Planning (Abandoned "x"));
  check bool "Completed->Executing" false (Plan.can_transition_to Completed Executing);
  check
    bool
    "Abandoned->Executing"
    false
    (Plan.can_transition_to (Abandoned "x") Executing)
;;

let test_plan_error_message_invalid () =
  let err =
    Plan.InvalidPlanTransition { from_status = Planning; to_status = Completed }
  in
  let msg = Plan.plan_transition_error_to_string err in
  check
    bool
    "contains invalid"
    true
    (try
       ignore (Str.search_forward (Str.regexp "invalid plan transition") msg 0);
       true
     with
     | Not_found -> false)
;;

let test_plan_error_message_terminal () =
  let err = Plan.PlanAlreadyTerminal { status = Completed } in
  let msg = Plan.plan_transition_error_to_string err in
  check
    bool
    "contains terminal"
    true
    (try
       ignore (Str.search_forward (Str.regexp "terminal") msg 0);
       true
     with
     | Not_found -> false)
;;

(* ── Suite ────────────────────────────────────────── *)

let () =
  run
    "plan"
    [ ( "creation"
      , [ test_case "create" `Quick test_create
        ; test_case "add steps" `Quick test_add_steps
        ] )
    ; ( "lifecycle"
      , [ test_case "step lifecycle" `Quick test_step_lifecycle
        ; test_case "fail step" `Quick test_fail_step
        ; test_case "skip step" `Quick test_skip_step
        ; test_case "is_done" `Quick test_is_done
        ] )
    ; ( "progress"
      , [ test_case "progress tracking" `Quick test_progress
        ; test_case "empty plan progress" `Quick test_progress_empty
        ] )
    ; ( "current_step"
      , [ test_case "running step" `Quick test_current_step_running
        ; test_case "first pending" `Quick test_current_step_pending
        ; test_case "all done" `Quick test_current_step_none
        ] )
    ; ( "dependencies"
      , [ test_case "single dep" `Quick test_deps_satisfied
        ; test_case "multi deps" `Quick test_deps_multi
        ; test_case "nonexistent step" `Quick test_deps_nonexistent
        ] )
    ; "replan", [ test_case "replan replaces pending" `Quick test_replan ]
    ; ( "serialization"
      , [ test_case "empty plan" `Quick test_serialization_empty
        ; test_case "with steps" `Quick test_serialization_with_steps
        ; test_case "abandoned" `Quick test_serialization_abandoned
        ; test_case "invalid json" `Quick test_deserialization_invalid
        ; test_case "status strings" `Quick test_status_strings
        ] )
    ; ( "transition_guards"
      , [ test_case "valid: Planning -> Executing" `Quick test_valid_planning_to_executing
        ; test_case
            "valid: Executing -> Replanning"
            `Quick
            test_valid_executing_to_replanning
        ; test_case
            "valid: Executing -> Completed"
            `Quick
            test_valid_executing_to_completed
        ; test_case
            "valid: Replanning -> Executing"
            `Quick
            test_valid_replanning_to_executing
        ; test_case "valid: abandon from Planning" `Quick test_valid_abandon_from_planning
        ; test_case
            "valid: abandon from Executing"
            `Quick
            test_valid_abandon_from_executing
        ; test_case
            "valid: abandon from Replanning"
            `Quick
            test_valid_abandon_from_replanning
        ; test_case
            "invalid: Planning -> Completed"
            `Quick
            test_invalid_planning_to_completed
        ; test_case
            "invalid: Planning -> Replanning"
            `Quick
            test_invalid_planning_to_replanning
        ; test_case
            "invalid: Executing -> Planning"
            `Quick
            test_invalid_executing_to_planning
        ; test_case "terminal: Completed rejects" `Quick test_terminal_completed_rejects
        ; test_case "terminal: Abandoned rejects" `Quick test_terminal_abandoned_rejects
        ; test_case
            "terminal: Abandoned rejects abandon"
            `Quick
            test_terminal_abandoned_rejects_abandon
        ; test_case "is_terminal_status" `Quick test_is_terminal_status
        ; test_case
            "valid_plan_transitions exhaustive"
            `Quick
            test_valid_plan_transitions_exhaustive
        ; test_case "can_transition_to" `Quick test_can_transition_to
        ; test_case
            "error message: InvalidPlanTransition"
            `Quick
            test_plan_error_message_invalid
        ; test_case
            "error message: PlanAlreadyTerminal"
            `Quick
            test_plan_error_message_terminal
        ] )
    ]
;;
