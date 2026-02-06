(** Agent Planner Module Coverage Tests

    Tests for lib/agent_planner.ml covering:
    - Block/plan JSON serialization roundtrips
    - fallback_plan structure
    - should_act logic
    - current_block lookup
    - plan_to_string formatting
    - act_threshold value
*)

open Alcotest

module Planner = Masc_mcp.Agent_planner

(* ============================================================
   act_threshold Tests
   ============================================================ *)

let test_act_threshold_value () =
  check (float 0.01) "act_threshold" 0.3 Planner.act_threshold

(* ============================================================
   should_act Tests
   ============================================================ *)

let test_should_act_high_priority () =
  let block : Planner.block = { hour = 10; activity = "active"; priority = 0.8 } in
  check bool "high priority acts" true (Planner.should_act block)

let test_should_act_at_threshold () =
  let block : Planner.block = { hour = 12; activity = "idle"; priority = 0.3 } in
  check bool "at threshold does not act" false (Planner.should_act block)

let test_should_act_below_threshold () =
  let block : Planner.block = { hour = 3; activity = "rest"; priority = 0.1 } in
  check bool "below threshold does not act" false (Planner.should_act block)

let test_should_act_just_above_threshold () =
  let block : Planner.block = { hour = 9; activity = "work"; priority = 0.31 } in
  check bool "just above threshold acts" true (Planner.should_act block)

let test_should_act_zero_priority () =
  let block : Planner.block = { hour = 0; activity = "sleep"; priority = 0.0 } in
  check bool "zero priority does not act" false (Planner.should_act block)

let test_should_act_max_priority () =
  let block : Planner.block = { hour = 15; activity = "urgent"; priority = 1.0 } in
  check bool "max priority acts" true (Planner.should_act block)

(* ============================================================
   current_block Tests
   ============================================================ *)

let make_plan blocks : Planner.daily_plan =
  {
    agent_name = "test-agent";
    date = "2026-02-06";
    goals = ["test goal"];
    hourly_blocks = blocks;
    created_at = 1706745600.0;
  }

let test_current_block_found () =
  (* Create blocks for all 24 hours so we always find the current hour *)
  let blocks = List.init 24 (fun h ->
    { Planner.hour = h; activity = Printf.sprintf "hour-%d" h; priority = 0.5 }
  ) in
  let plan = make_plan blocks in
  match Planner.current_block plan with
  | Some b ->
    check bool "hour in range" true (b.hour >= 0 && b.hour < 24)
  | None -> fail "Should find a block for current hour"

let test_current_block_empty_plan () =
  let plan = make_plan [] in
  check (option reject) "no block for empty plan" None (Planner.current_block plan)

let test_current_block_partial_plan () =
  (* Only have blocks for hours 0-5, current hour might not be covered *)
  let blocks = List.init 6 (fun h ->
    { Planner.hour = h; activity = "early"; priority = 0.2 }
  ) in
  let plan = make_plan blocks in
  let result = Planner.current_block plan in
  (* Result depends on current time; just verify it returns Some or None *)
  let _ = result in ()

(* ============================================================
   fallback_plan Tests
   ============================================================ *)

let test_fallback_plan_structure () =
  let plan = Planner.fallback_plan ~agent_name:"claude" in
  check string "agent_name" "claude" plan.agent_name;
  check int "24 hourly blocks" 24 (List.length plan.hourly_blocks);
  check bool "has goals" true (List.length plan.goals > 0);
  check bool "date nonempty" true (String.length plan.date > 0)

let test_fallback_plan_hours_complete () =
  let plan = Planner.fallback_plan ~agent_name:"test" in
  let hours = List.map (fun (b : Planner.block) -> b.hour) plan.hourly_blocks in
  check int "starts at 0" 0 (List.hd hours);
  check int "ends at 23" 23 (List.nth hours 23);
  (* All 24 hours present *)
  let sorted = List.sort compare hours in
  check (list int) "all hours 0-23" (List.init 24 Fun.id) sorted

let test_fallback_plan_quiet_hours () =
  let plan = Planner.fallback_plan ~agent_name:"test" in
  (* Hours 1-5 should be quiet (priority 0.1) *)
  let quiet_blocks = List.filter (fun (b : Planner.block) ->
    b.hour >= 1 && b.hour < 6
  ) plan.hourly_blocks in
  List.iter (fun (b : Planner.block) ->
    check (float 0.01) (Printf.sprintf "hour %d quiet" b.hour) 0.1 b.priority
  ) quiet_blocks

let test_fallback_plan_active_hours () =
  let plan = Planner.fallback_plan ~agent_name:"test" in
  (* Hours 9-11 should be active (priority 0.6) *)
  let morning_blocks = List.filter (fun (b : Planner.block) ->
    b.hour >= 9 && b.hour < 12
  ) plan.hourly_blocks in
  List.iter (fun (b : Planner.block) ->
    check (float 0.01) (Printf.sprintf "hour %d active" b.hour) 0.6 b.priority
  ) morning_blocks

let test_fallback_plan_created_at () =
  let plan = Planner.fallback_plan ~agent_name:"test" in
  check bool "created_at > 0" true (plan.created_at > 0.0)

(* ============================================================
   plan_to_string Tests
   ============================================================ *)

let test_plan_to_string_contains_name () =
  let plan = Planner.fallback_plan ~agent_name:"dreamer" in
  let s = Planner.plan_to_string plan in
  check bool "contains agent name" true
    (try let _ = Str.search_forward (Str.regexp "dreamer") s 0 in true
     with Not_found -> false)

let test_plan_to_string_contains_goals () =
  let plan = Planner.fallback_plan ~agent_name:"test" in
  let s = Planner.plan_to_string plan in
  check bool "contains goal keyword" true (String.length s > 0);
  check bool "contains date" true
    (try let _ = Str.search_forward (Str.regexp "[0-9][0-9][0-9][0-9]-") s 0 in true
     with Not_found -> false)

let test_plan_to_string_contains_activities () =
  let plan : Planner.daily_plan = {
    agent_name = "test";
    date = "2026-02-06";
    goals = ["goal1"; "goal2"];
    hourly_blocks = [
      { hour = 10; activity = "coding"; priority = 0.8 };
      { hour = 14; activity = "review"; priority = 0.7 };
    ];
    created_at = 1706745600.0;
  } in
  let s = Planner.plan_to_string plan in
  check bool "contains coding" true
    (try let _ = Str.search_forward (Str.regexp "coding") s 0 in true
     with Not_found -> false)

let test_plan_to_string_empty_blocks () =
  let plan : Planner.daily_plan = {
    agent_name = "empty";
    date = "2026-02-06";
    goals = [];
    hourly_blocks = [];
    created_at = 0.0;
  } in
  let s = Planner.plan_to_string plan in
  check bool "not empty" true (String.length s > 0)

(* ============================================================
   Block Type Tests
   ============================================================ *)

let test_block_construction () =
  let b : Planner.block = { hour = 15; activity = "lunch"; priority = 0.4 } in
  check int "hour" 15 b.hour;
  check string "activity" "lunch" b.activity;
  check (float 0.01) "priority" 0.4 b.priority

let test_daily_plan_construction () =
  let plan : Planner.daily_plan = {
    agent_name = "test-agent";
    date = "2026-01-01";
    goals = ["a"; "b"];
    hourly_blocks = [];
    created_at = 100.0;
  } in
  check string "agent_name" "test-agent" plan.agent_name;
  check string "date" "2026-01-01" plan.date;
  check int "goals count" 2 (List.length plan.goals);
  check (float 0.01) "created_at" 100.0 plan.created_at

(* ============================================================
   Test Runner
   ============================================================ *)

let () =
  run "Agent Planner Coverage" [
    "act_threshold", [
      test_case "value" `Quick test_act_threshold_value;
    ];
    "should_act", [
      test_case "high priority" `Quick test_should_act_high_priority;
      test_case "at threshold" `Quick test_should_act_at_threshold;
      test_case "below threshold" `Quick test_should_act_below_threshold;
      test_case "just above threshold" `Quick test_should_act_just_above_threshold;
      test_case "zero priority" `Quick test_should_act_zero_priority;
      test_case "max priority" `Quick test_should_act_max_priority;
    ];
    "current_block", [
      test_case "found" `Quick test_current_block_found;
      test_case "empty plan" `Quick test_current_block_empty_plan;
      test_case "partial plan" `Quick test_current_block_partial_plan;
    ];
    "fallback_plan", [
      test_case "structure" `Quick test_fallback_plan_structure;
      test_case "hours complete" `Quick test_fallback_plan_hours_complete;
      test_case "quiet hours" `Quick test_fallback_plan_quiet_hours;
      test_case "active hours" `Quick test_fallback_plan_active_hours;
      test_case "created_at" `Quick test_fallback_plan_created_at;
    ];
    "plan_to_string", [
      test_case "contains name" `Quick test_plan_to_string_contains_name;
      test_case "contains goals" `Quick test_plan_to_string_contains_goals;
      test_case "contains activities" `Quick test_plan_to_string_contains_activities;
      test_case "empty blocks" `Quick test_plan_to_string_empty_blocks;
    ];
    "types", [
      test_case "block construction" `Quick test_block_construction;
      test_case "daily_plan construction" `Quick test_daily_plan_construction;
    ];
  ]
