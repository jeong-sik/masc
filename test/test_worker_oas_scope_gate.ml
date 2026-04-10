(** Tests for Worker_oas execution scope gate enforcement.

    Verifies that Observe_only scope denies MASC mutating tools,
    code mutation tools, and destructive operations. *)

open Alcotest
open Masc_mcp

let test_observe_only_denies_masc_mutating () =
  let gate = Worker_oas.gate_config_of_execution_scope Worker_types.Observe_only in
  let mutating_tools =
    [ "masc_worktree_create"; "masc_worktree_remove";
      "masc_add_task"; "masc_transition";
      "masc_complete_task";  (* alias of masc_transition *)
      "masc_set_current_task";  (* alias of masc_plan_set_task *)
      "masc_operator_action"; "masc_room_delete" ]
  in
  List.iter (fun tool ->
    check bool (tool ^ " denied in Observe_only") true
      (List.mem tool gate.Eval_gate.denied_tools))
    mutating_tools

let test_observe_only_denies_code_mutation () =
  let gate = Worker_oas.gate_config_of_execution_scope Worker_types.Observe_only in
  let code_tools =
    [ "keeper_bash"; "masc_code_write"; "masc_code_edit" ]
  in
  List.iter (fun tool ->
    check bool (tool ^ " denied in Observe_only") true
      (List.mem tool gate.Eval_gate.denied_tools))
    code_tools

let test_limited_allows_masc_mutating () =
  let gate = Worker_oas.gate_config_of_execution_scope Worker_types.Limited_code_change in
  check bool "masc_worktree_create allowed in Limited" false
    (List.mem "masc_worktree_create" gate.Eval_gate.denied_tools);
  check bool "masc_add_task allowed in Limited" false
    (List.mem "masc_add_task" gate.Eval_gate.denied_tools)

let test_limited_denies_destructive () =
  let gate = Worker_oas.gate_config_of_execution_scope Worker_types.Limited_code_change in
  check bool "shell_exec_dangerous denied in Limited" true
    (List.mem "shell_exec_dangerous" gate.Eval_gate.denied_tools)

let test_autonomous_allows_all () =
  let gate = Worker_oas.gate_config_of_execution_scope Worker_types.Autonomous in
  check bool "no denied tools in Autonomous" true
    (List.length gate.Eval_gate.denied_tools = 0)

let test_observe_only_allows_read_tools () =
  let gate = Worker_oas.gate_config_of_execution_scope Worker_types.Observe_only in
  let read_tools = [ "masc_status"; "masc_tasks"; "masc_who" ] in
  List.iter (fun tool ->
    check bool (tool ^ " allowed in Observe_only") false
      (List.mem tool gate.Eval_gate.denied_tools))
    read_tools

let () =
  run "Worker_oas_scope_gate"
  [
    ("observe_only", [
      test_case "denies MASC mutating tools" `Quick
        test_observe_only_denies_masc_mutating;
      test_case "denies code mutation tools" `Quick
        test_observe_only_denies_code_mutation;
      test_case "allows read-only tools" `Quick
        test_observe_only_allows_read_tools;
    ]);
    ("limited_code_change", [
      test_case "allows MASC mutating tools" `Quick
        test_limited_allows_masc_mutating;
      test_case "denies destructive tools" `Quick
        test_limited_denies_destructive;
    ]);
    ("autonomous", [
      test_case "allows all tools" `Quick
        test_autonomous_allows_all;
    ]);
  ]
