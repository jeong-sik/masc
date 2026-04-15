(** Tests for Worker safety gates in pre_tool_use hook.

    Verifies the 3-gate defense-in-depth:
    - Gate 0: Deny list
    - Gate 1: Cost budget
    - Gate 2: Destructive pattern detection

    Uses Masc_mcp.Worker_oas.make_tool_tracking_hooks with gate_config. *)

open Alcotest

(* ── Aliases ──────────────────────────────────── *)

module WO = Masc_mcp.Worker_oas
module EG = Masc_mcp.Eval_gate

(* Populate destructive set — in production this is done by mcp_server_eio.ml *)
let () = Masc_mcp.Tool_dispatch.init_destructive_set
  ["keeper_bash"; "keeper_fs_edit";
   "shell_exec"; "masc_code_shell"; "masc_code_git"; "masc_code_delete"]

(* ── Helpers ──────────────────────────────────── *)

let dummy_schedule : Agent_sdk.Hooks.tool_schedule = {
  planned_index = 0;
  batch_index = 0;
  batch_size = 1;
  concurrency_class = "default";
  batch_kind = "sequential";
}

(** Simulate a PreToolUse event and return the hook_result. *)
let fire_pre_tool_use ~hooks ~tool_name ~input ~accumulated_cost_usd =
  match hooks.Agent_sdk.Hooks.pre_tool_use with
  | None -> Agent_sdk.Hooks.Continue
  | Some handler ->
    handler
      (Agent_sdk.Hooks.PreToolUse {
         tool_use_id = "tu_test";
         tool_name;
         input;
         accumulated_cost_usd;
         turn = 1;
         schedule = dummy_schedule;
       })

let default_gate ?(denied_tools=[]) ?(max_cost_usd=1.0)
    ?(destructive_check_enabled=true) () : EG.gate_config =
  { EG.default_config with
    denied_tools;
    max_cost_usd;
    destructive_check_enabled;
  }

(* ── Test: no gate_config = tracking only ────── *)

let test_no_gate_allows_all () =
  let tool_names_ref, hooks = WO.make_tool_tracking_hooks () in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"anything"
      ~input:`Null
      ~accumulated_cost_usd:0.0
  in
  check bool "continues" true
    (result = Agent_sdk.Hooks.Continue);
  check bool "tool tracked" true
    (List.mem "anything" !tool_names_ref)

(* ── Test: Gate 0 — Deny list ────────────────── *)

let test_deny_list_blocks () =
  let gate_config = default_gate ~denied_tools:["evil_tool"] () in
  let tool_names_ref, hooks =
    WO.make_tool_tracking_hooks ~gate_config ()
  in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"evil_tool"
      ~input:`Null
      ~accumulated_cost_usd:0.0
  in
  (match result with
   | Agent_sdk.Hooks.Override msg ->
     check bool "contains reason" true
       (Astring.String.is_infix ~affix:"worker_deny" msg)
   | _ -> fail "expected Override for denied tool");
  (* Tool name is still tracked even when blocked *)
  check bool "tool tracked" true
    (List.mem "evil_tool" !tool_names_ref)

let test_deny_list_allows_non_denied () =
  let gate_config = default_gate ~denied_tools:["evil_tool"] () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"good_tool"
      ~input:`Null
      ~accumulated_cost_usd:0.0
  in
  check bool "continues" true
    (result = Agent_sdk.Hooks.Continue)

(* ── Test: Gate 1 — Cost budget ──────────────── *)

let test_cost_gate_blocks_over_budget () =
  let gate_config = default_gate ~max_cost_usd:0.50 () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"any_tool"
      ~input:`Null
      ~accumulated_cost_usd:0.55
  in
  (match result with
   | Agent_sdk.Hooks.Override msg ->
     check bool "contains cost_gate" true
       (Astring.String.is_infix ~affix:"cost_gate" msg)
   | _ -> fail "expected Override for cost budget exceeded")

let test_cost_gate_blocks_at_exact_limit () =
  let gate_config = default_gate ~max_cost_usd:0.50 () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"any_tool"
      ~input:`Null
      ~accumulated_cost_usd:0.50
  in
  (match result with
   | Agent_sdk.Hooks.Override msg ->
     check bool "contains cost_gate" true
       (Astring.String.is_infix ~affix:"cost_gate" msg)
   | _ -> fail "expected Override at exact budget limit")

let test_cost_gate_allows_under_budget () =
  let gate_config = default_gate ~max_cost_usd:1.0 () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"any_tool"
      ~input:`Null
      ~accumulated_cost_usd:0.30
  in
  check bool "continues" true
    (result = Agent_sdk.Hooks.Continue)

(* ── Test: Gate 2 — Destructive pattern ──────── *)

let test_destructive_blocks_rm_rf () =
  let gate_config = default_gate () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let input = `Assoc [("command", `String "rm -rf /")] in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"shell_exec"
      ~input
      ~accumulated_cost_usd:0.0
  in
  (match result with
   | Agent_sdk.Hooks.Override msg ->
     check bool "contains destructive_guard" true
       (Astring.String.is_infix ~affix:"destructive_guard" msg)
   | _ -> fail "expected Override for destructive pattern")

let test_destructive_allows_safe_command () =
  let gate_config = default_gate () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let input = `Assoc [("command", `String "ls -la")] in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"shell_exec"
      ~input
      ~accumulated_cost_usd:0.0
  in
  check bool "continues" true
    (result = Agent_sdk.Hooks.Continue)

let test_destructive_skips_non_shell_tools () =
  let gate_config = default_gate () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let input = `Assoc [("command", `String "rm -rf /")] in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"masc_status"
      ~input
      ~accumulated_cost_usd:0.0
  in
  check bool "continues (non-shell tool)" true
    (result = Agent_sdk.Hooks.Continue)

let test_destructive_disabled () =
  let gate_config = default_gate ~destructive_check_enabled:false () in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let input = `Assoc [("command", `String "rm -rf /")] in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"shell_exec"
      ~input
      ~accumulated_cost_usd:0.0
  in
  check bool "continues (destructive check disabled)" true
    (result = Agent_sdk.Hooks.Continue)

(* ── Test: Gate priority (deny > cost > destructive) ── *)

let test_deny_takes_priority_over_cost () =
  let gate_config =
    default_gate ~denied_tools:["shell_exec"] ~max_cost_usd:0.50 ()
  in
  let _ref, hooks = WO.make_tool_tracking_hooks ~gate_config () in
  let result =
    fire_pre_tool_use ~hooks
      ~tool_name:"shell_exec"
      ~input:(`Assoc [("command", `String "rm -rf /")])
      ~accumulated_cost_usd:0.55
  in
  (match result with
   | Agent_sdk.Hooks.Override msg ->
     (* Should be denied by deny list, not cost gate *)
     check bool "deny list first" true
       (Astring.String.is_infix ~affix:"worker_deny" msg)
   | _ -> fail "expected Override")

(* ── Runner ──────────────────────────────────── *)

let () =
  run "Worker Safety Gates"
    [
      ( "no_gate",
        [
          test_case "allows all tools" `Quick test_no_gate_allows_all;
        ] );
      ( "deny_list",
        [
          test_case "blocks denied tool" `Quick test_deny_list_blocks;
          test_case "allows non-denied tool" `Quick
            test_deny_list_allows_non_denied;
        ] );
      ( "cost_gate",
        [
          test_case "blocks over budget" `Quick
            test_cost_gate_blocks_over_budget;
          test_case "blocks at exact limit" `Quick
            test_cost_gate_blocks_at_exact_limit;
          test_case "allows under budget" `Quick
            test_cost_gate_allows_under_budget;
        ] );
      ( "destructive",
        [
          test_case "blocks rm -rf" `Quick test_destructive_blocks_rm_rf;
          test_case "allows safe command" `Quick
            test_destructive_allows_safe_command;
          test_case "skips non-shell tools" `Quick
            test_destructive_skips_non_shell_tools;
          test_case "disabled flag" `Quick test_destructive_disabled;
        ] );
      ( "priority",
        [
          test_case "deny > cost > destructive" `Quick
            test_deny_takes_priority_over_cost;
        ] );
    ]
