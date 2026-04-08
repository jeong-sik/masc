(** Tests for Workflow_guide — Golden Path encoding and next_steps. *)

(* Use canonical prefix due to OCaml 5.x -H flag interaction *)
module WG = Masc_mcp__Workflow_guide

open Alcotest

(* ── Helpers ─────────────────────────────────────────────────────── *)

let check_has_tool steps tool_name =
  let found =
    List.exists
      (fun (s : WG.step) -> s.tool = tool_name)
      steps
  in
  check bool (Printf.sprintf "next_steps contains %s" tool_name) true found

let check_not_empty msg steps =
  check bool msg true (List.length steps > 0)

(* ── Golden Path 1: Room/Task Hygiene ────────────────────────────── *)

let test_start_success () =
  let g = WG.next_steps ~tool_name:"masc_start" ~success:true in
  check_not_empty "start success has next_steps" g.next_steps;
  check_has_tool g.next_steps "masc_worktree_create"

let test_start_failure () =
  let g = WG.next_steps ~tool_name:"masc_start" ~success:false in
  check_not_empty "start failure has recovery steps" g.next_steps;
  check_has_tool g.next_steps "masc_start";
  check_has_tool g.next_steps "masc_init"

let test_join_success () =
  let g = WG.next_steps ~tool_name:"masc_join" ~success:true in
  check_has_tool g.next_steps "masc_status";
  check_has_tool g.next_steps "masc_transition";
  check bool "join has preconditions" true (List.length g.preconditions > 0)

let test_join_failure () =
  let g = WG.next_steps ~tool_name:"masc_join" ~success:false in
  check_has_tool g.next_steps "masc_start"

let test_claim_success () =
  let g = WG.next_steps ~tool_name:"masc_claim_next" ~success:true in
  check_has_tool g.next_steps "masc_worktree_create";
  check bool "claim has common_mistakes" true (List.length g.common_mistakes > 0)

let test_plan_set_task_success () =
  let g = WG.next_steps ~tool_name:"masc_plan_set_task" ~success:true in
  check_has_tool g.next_steps "masc_worktree_create"

let test_done_success () =
  let g = WG.next_steps ~tool_name:"masc_done" ~success:true in
  check_has_tool g.next_steps "masc_status";
  check_has_tool g.next_steps "masc_transition"

(* ── Golden Path 2: CPv2 ─────────────────────────────────────────── *)

let test_operation_start_success () =
  let g = WG.next_steps ~tool_name:"masc_operation_start" ~success:true in
  check_has_tool g.next_steps "masc_dispatch_tick"

let test_dispatch_tick_success () =
  let g = WG.next_steps ~tool_name:"masc_dispatch_tick" ~success:true in
  check_has_tool g.next_steps "masc_observe_operations"

(* ── Golden Path 3: Team Session ─────────────────────────────────── *)

let test_team_session_start_success () =
  let g = WG.next_steps ~tool_name:"masc_team_session_start" ~success:true in
  check_has_tool g.next_steps "masc_team_session_step"

let test_team_session_prove_success () =
  let g = WG.next_steps ~tool_name:"masc_team_session_prove" ~success:true in
  check_has_tool g.next_steps "masc_team_session_stop"

(* ── Unknown tools return empty guidance ─────────────────────────── *)

let test_unknown_tool () =
  let g = WG.next_steps ~tool_name:"masc_nonexistent_tool" ~success:true in
  check (list string) "unknown tool returns empty next_steps" []
    (List.map (fun (s : WG.step) -> s.tool) g.next_steps)

(* ── JSON serialization ──────────────────────────────────────────── *)

let test_guidance_to_json_null_for_empty () =
  let g = WG.next_steps ~tool_name:"masc_nonexistent" ~success:true in
  let json = WG.guidance_to_json g in
  check bool "empty guidance serializes to Null" true (json = `Null)

let test_guidance_to_json_has_next_steps () =
  let g = WG.next_steps ~tool_name:"masc_join" ~success:true in
  let json = WG.guidance_to_json g in
  match json with
  | `Assoc fields ->
      check bool "JSON has next_steps field" true (List.mem_assoc "next_steps" fields)
  | _ -> fail "Expected Assoc for non-empty guidance"

(* ── Workflow context for tool help ──────────────────────────────── *)

let test_workflow_context_join () =
  match WG.workflow_context ~tool_name:"masc_join" with
  | Some (before, after, _mistakes) ->
      check bool "join before includes start" true
        (List.mem "masc_start" before);
      check bool "join after is non-empty" true (List.length after > 0)
  | None -> fail "Expected workflow context for masc_join"

let test_workflow_context_unknown () =
  let ctx = WG.workflow_context ~tool_name:"masc_nonexistent" in
  check bool "unknown tool has no workflow context" true (ctx = None)

(* ── State-based guidance ────────────────────────────────────────── *)

let test_state_not_room_set () =
  let g = WG.current_state_guidance
    ~room_set:false ~joined:false ~task_claimed:false
    ~current_task_set:false ~worktree_active:false ~session_active:false
  in
  check_has_tool g.next_steps "masc_start"

let test_state_room_set_not_joined () =
  let g = WG.current_state_guidance
    ~room_set:true ~joined:false ~task_claimed:false
    ~current_task_set:false ~worktree_active:false ~session_active:false
  in
  check_has_tool g.next_steps "masc_join"

let test_state_joined_no_task () =
  let g = WG.current_state_guidance
    ~room_set:true ~joined:true ~task_claimed:false
    ~current_task_set:false ~worktree_active:false ~session_active:false
  in
  check_has_tool g.next_steps "masc_transition"

let test_state_task_claimed_no_current () =
  let g = WG.current_state_guidance
    ~room_set:true ~joined:true ~task_claimed:true
    ~current_task_set:false ~worktree_active:false ~session_active:false
  in
  check_has_tool g.next_steps "masc_plan_set_task"

let test_state_ready_to_work () =
  let g = WG.current_state_guidance
    ~room_set:true ~joined:true ~task_claimed:true
    ~current_task_set:true ~worktree_active:true ~session_active:false
  in
  check_has_tool g.next_steps "masc_heartbeat"

(* ── Alias coverage ──────────────────────────────────────────────── *)

let test_claim_next_alias () =
  let g = WG.next_steps ~tool_name:"masc_claim_next" ~success:true in
  check_has_tool g.next_steps "masc_worktree_create"

let test_set_current_task_alias_matches_canonical () =
  let alias_steps =
    WG.next_steps ~tool_name:"masc_set_current_task" ~success:true
    |> fun g -> List.map (fun (s : WG.step) -> s.tool) g.next_steps
  in
  let canonical_steps =
    WG.next_steps ~tool_name:"masc_plan_set_task" ~success:true
    |> fun g -> List.map (fun (s : WG.step) -> s.tool) g.next_steps
  in
  check (list string) "alias guidance matches canonical guidance"
    canonical_steps alias_steps

let test_complete_task_removed () =
  (* masc_complete_task was a ghost tool — it no longer routes to guidance *)
  let g = WG.next_steps ~tool_name:"masc_complete_task" ~success:true in
  check (list string) "removed ghost returns empty" []
    (List.map (fun (s : WG.step) -> s.tool) g.next_steps)

let test_transition_generic_is_safe () =
  let g = WG.next_steps ~tool_name:"masc_transition" ~success:true in
  check_has_tool g.next_steps "masc_status";
  check_has_tool g.next_steps "masc_workflow_guide"

let test_transition_claim_call_guidance () =
  let g =
    WG.next_steps_for_call ~tool_name:"masc_transition"
      ~args:(`Assoc [ ("action", `String "claim"); ("task_id", `String "task-001") ])
      ~success:true
  in
  check_has_tool g.next_steps "masc_plan_set_task"

let test_transition_done_call_guidance () =
  let g =
    WG.next_steps_for_call ~tool_name:"masc_transition"
      ~args:(`Assoc [ ("action", `String "done"); ("task_id", `String "task-001") ])
      ~success:true
  in
  check_has_tool g.next_steps "masc_status";
  check bool "done guidance omits plan_set_task" false
    (List.exists (fun (s : WG.step) -> s.tool = "masc_plan_set_task") g.next_steps)

let test_transition_release_call_guidance () =
  let g =
    WG.next_steps_for_call ~tool_name:"masc_transition"
      ~args:(`Assoc [ ("action", `String "release"); ("task_id", `String "task-001") ])
      ~success:true
  in
  check_has_tool g.next_steps "masc_status";
  check bool "release guidance omits plan_set_task" false
    (List.exists (fun (s : WG.step) -> s.tool = "masc_plan_set_task") g.next_steps)

(* Structural: all tool names in guidance output exist in Config.all_tool_schemas *)
let all_schema_names =
  List.map (fun (s : Types.tool_schema) -> s.name) Masc_mcp.Config.all_tool_schemas

let check_tool_exists_in_schemas name =
  if not (List.mem name all_schema_names) then
    Alcotest.fail
      (Printf.sprintf "Workflow_guide references tool '%s' not in Config.all_tool_schemas" name)

let test_next_steps_reference_real_tools () =
  let tools_to_check = [
    "masc_start"; "masc_join"; "masc_status";
    "masc_claim"; "masc_claim_next";
    "masc_done"; "masc_transition";
    "masc_add_task"; "masc_batch_add_tasks";
    "masc_plan_set_task"; "masc_set_current_task";
    "masc_heartbeat"; "masc_broadcast";
    "masc_worktree_create"; "masc_init";
    "masc_operator_digest";
  ] in
  List.iter (fun tool_name ->
    let g_ok = WG.next_steps ~tool_name ~success:true in
    List.iter (fun (s : WG.step) -> check_tool_exists_in_schemas s.tool) g_ok.next_steps;
    let g_fail = WG.next_steps ~tool_name ~success:false in
    List.iter (fun (s : WG.step) -> check_tool_exists_in_schemas s.tool) g_fail.next_steps
  ) tools_to_check

(* ── Test runner ─────────────────────────────────────────────────── *)

let () =
  run "Workflow_guide" [
    "golden_path_1", [
      test_case "start success" `Quick test_start_success;
      test_case "start failure" `Quick test_start_failure;
      test_case "join success" `Quick test_join_success;
      test_case "join failure" `Quick test_join_failure;
      test_case "claim success" `Quick test_claim_success;
      test_case "plan_set_task success" `Quick test_plan_set_task_success;
      test_case "done success" `Quick test_done_success;
      test_case "set_current_task alias matches canonical" `Quick
        test_set_current_task_alias_matches_canonical;
    ];
    "golden_path_2", [
      test_case "operation_start success" `Quick test_operation_start_success;
      test_case "dispatch_tick success" `Quick test_dispatch_tick_success;
    ];
    "golden_path_3", [
      test_case "team_session_start success" `Quick test_team_session_start_success;
      test_case "team_session_prove success" `Quick test_team_session_prove_success;
    ];
    "edge_cases", [
      test_case "unknown tool" `Quick test_unknown_tool;
      test_case "claim_next alias" `Quick test_claim_next_alias;
      test_case "complete_task removed" `Quick test_complete_task_removed;
      test_case "transition generic is safe" `Quick test_transition_generic_is_safe;
      test_case "transition claim call guidance" `Quick test_transition_claim_call_guidance;
      test_case "transition done call guidance" `Quick test_transition_done_call_guidance;
      test_case "transition release call guidance" `Quick test_transition_release_call_guidance;
    ];
    "structural", [
      test_case "next_steps reference real tools" `Quick test_next_steps_reference_real_tools;
    ];
    "json", [
      test_case "null for empty" `Quick test_guidance_to_json_null_for_empty;
      test_case "has next_steps" `Quick test_guidance_to_json_has_next_steps;
    ];
    "workflow_context", [
      test_case "join context" `Quick test_workflow_context_join;
      test_case "unknown context" `Quick test_workflow_context_unknown;
    ];
    "state_guidance", [
      test_case "not room set" `Quick test_state_not_room_set;
      test_case "room set not joined" `Quick test_state_room_set_not_joined;
      test_case "joined no task" `Quick test_state_joined_no_task;
      test_case "task claimed no current" `Quick test_state_task_claimed_no_current;
      test_case "ready to work" `Quick test_state_ready_to_work;
    ];
  ]
