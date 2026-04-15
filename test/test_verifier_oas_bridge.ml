(** test_verifier_oas_bridge — Pure tests for Verifier_oas bridge functions.

    Covers eval_gate_to_oas_guardrails, verdict_to_hook_decision,
    and read_only_predicate without any MODEL or network calls.

    @since OAS Integration Phase 2 *)

open Masc_mcp

module Oas = Agent_sdk

(* ================================================================ *)
(* Helpers                                                           *)
(* ================================================================ *)

let make_gate
    ?(max_cost = 0.50)
    ?(max_calls = 10)
    ?(entropy = 3)
    ?(destructive = true)
    ?(allowlist_enabled = false)
    ?(allowed = [])
    ?(denied = [])
    () : Eval_gate.gate_config =
  {
    max_cost_usd = max_cost;
    max_tool_calls_per_turn = max_calls;
    entropy_threshold = entropy;
    destructive_check_enabled = destructive;
    allowlist_enabled;
    allowed_tools = allowed;
    denied_tools = denied;
  }

let make_schema name : Oas.Types.tool_schema =
  { name; description = ""; parameters = [] }

(* ================================================================ *)
(* eval_gate_to_oas_guardrails                                       *)
(* ================================================================ *)

let test_allowlist_maps_to_allowlist () =
  let gate =
    make_gate ~allowlist_enabled:true
      ~allowed:["keeper_read"; "keeper_bash"]
      ~denied:["keeper_fs_edit"]
      ()
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "allowlist takes priority"
    true
    (match g.tool_filter with
     | Oas.Guardrails.AllowList names ->
         List.sort String.compare names
         = List.sort String.compare ["keeper_read"; "keeper_bash"]
     | _ -> false);
  Alcotest.(check (option int)) "max_tool_calls preserved"
    (Some 10) g.max_tool_calls_per_turn

let test_denylist_maps_to_denylist () =
  let gate =
    make_gate ~allowlist_enabled:false
      ~denied:["keeper_bash"; "keeper_fs_edit"]
      ()
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "denied only -> DenyList"
    true
    (match g.tool_filter with
     | Oas.Guardrails.DenyList names ->
         List.sort String.compare names
         = List.sort String.compare ["keeper_bash"; "keeper_fs_edit"]
     | _ -> false)

let test_neither_maps_to_allowall () =
  let gate =
    make_gate ~allowlist_enabled:false ~allowed:[] ~denied:[] ()
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "neither -> AllowAll"
    true
    (match g.tool_filter with
     | Oas.Guardrails.AllowAll -> true
     | _ -> false)

let test_empty_allowlist_maps_to_empty_allowlist () =
  let gate =
    make_gate ~allowlist_enabled:true ~allowed:[] ()
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "empty allowlist -> AllowList []"
    true
    (match g.tool_filter with
     | Oas.Guardrails.AllowList [] -> true
     | _ -> false)

let test_max_tool_calls_preserved () =
  let gate = make_gate ~max_calls:5 () in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check (option int)) "max_tool_calls = 5"
    (Some 5) g.max_tool_calls_per_turn

let test_allowlist_ignores_denied_when_both () =
  let gate =
    make_gate ~allowlist_enabled:true
      ~allowed:["keeper_read"]
      ~denied:["keeper_bash"]
      ()
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "allowlist wins over denylist"
    true
    (match g.tool_filter with
     | Oas.Guardrails.AllowList ["keeper_read"] -> true
     | _ -> false)

(* ================================================================ *)
(* verdict_to_hook_decision                                          *)
(* ================================================================ *)

let test_pass_to_continue () =
  let decision = Verifier_oas.verdict_to_hook_decision Pass in
  Alcotest.(check bool) "Pass -> Continue"
    true
    (decision = Oas.Hooks.Continue)

let test_warn_to_continue () =
  let decision = Verifier_oas.verdict_to_hook_decision (Warn "minor issue") in
  Alcotest.(check bool) "Warn -> Continue"
    true
    (decision = Oas.Hooks.Continue)

let test_fail_to_skip () =
  let decision = Verifier_oas.verdict_to_hook_decision (Fail "critical error") in
  Alcotest.(check bool) "Fail -> Skip"
    true
    (decision = Oas.Hooks.Skip)

(* ================================================================ *)
(* read_only_predicate                                               *)
(* ================================================================ *)

let test_read_tools_are_readonly () =
  (* Word boundary matching: underscore IS a word char, so "keeper_read"
     does NOT match "read". Only tools with standalone patterns match. *)
  let read_tools = [
    "read file"; "grep code"; "search files";
    "find module"; "list dir"; "ls output";
    "git status"; "git log"; "git diff";
    "view file"; "get status";
    "fetch data"; "query db";
  ] in
  List.iter (fun name ->
    let schema = make_schema name in
    Alcotest.(check bool) (Printf.sprintf "%s is read-only" name)
      true
      (Verifier_oas.read_only_predicate schema)
  ) read_tools

let test_write_tools_are_not_readonly () =
  let write_tools = [
    "keeper_bash"; "keeper_fs_edit";
    "write_file"; "delete_node";
    (* underscore-joined: "read" is NOT at word boundary *)
    "keeper_read"; "bulk_search";
  ] in
  List.iter (fun name ->
    let schema = make_schema name in
    Alcotest.(check bool) (Printf.sprintf "%s is NOT read-only" name)
      false
      (Verifier_oas.read_only_predicate schema)
  ) write_tools

(* ================================================================ *)
(* parse_verdict                                                     *)
(* ================================================================ *)

let test_parse_verdict_pass () =
  Alcotest.(check bool) "PASS" true
    (Verifier_oas.parse_verdict "PASS" = Ok Pass)

let test_parse_verdict_pass_with_trailing () =
  Alcotest.(check bool) "PASS with trailing" true
    (Verifier_oas.parse_verdict "PASS - looks good" = Ok Pass)

let test_parse_verdict_warn () =
  match Verifier_oas.parse_verdict "WARN: minor issue" with
  | Ok (Warn reason) ->
    Alcotest.(check bool) "reason preserved" true
      (String.length reason > 0)
  | _ -> Alcotest.fail "expected Ok (Warn _)"

let test_parse_verdict_fail () =
  match Verifier_oas.parse_verdict "FAIL: critical error" with
  | Ok (Fail reason) ->
    Alcotest.(check bool) "reason preserved" true
      (String.length reason > 0)
  | _ -> Alcotest.fail "expected Ok (Fail _)"

let test_parse_verdict_case_insensitive () =
  Alcotest.(check bool) "pass lowercase" true
    (Verifier_oas.parse_verdict "pass" = Ok Pass)

let test_parse_verdict_unknown_returns_error () =
  match Verifier_oas.parse_verdict "something unexpected" with
  | Error msg ->
    Alcotest.(check bool) "error mentions format" true
      (String.length msg > 0)
  | Ok _ -> Alcotest.fail "unknown text should return Error"

let test_parse_verdict_empty_returns_error () =
  match Verifier_oas.parse_verdict "" with
  | Error msg ->
    Alcotest.(check string) "empty output error"
      "empty verifier output" msg
  | Ok _ -> Alcotest.fail "empty text should return Error"

let test_parse_verdict_rejects_passing_prefix () =
  match Verifier_oas.parse_verdict "PASSING all checks" with
  | Error msg ->
    Alcotest.(check bool) "PASSING rejected" true
      (String.length msg > 0)
  | Ok _ -> Alcotest.fail "PASSING should be rejected as invalid verdict"

let test_parse_verdict_rejects_warning_prefix () =
  match Verifier_oas.parse_verdict "WARNING: system alert" with
  | Error msg ->
    Alcotest.(check bool) "WARNING rejected" true
      (String.length msg > 0)
  | Ok _ -> Alcotest.fail "WARNING should be rejected as invalid verdict"

(* ================================================================ *)
(* should_skip (verify fast path)                                    *)
(* ================================================================ *)

let test_verify_skips_readonly () =
  let req : Verifier_oas.verification_request = {
    action_description = "read file contents";
    action_result = "some data";
    goal = "test goal";
    context_summary = "test context";
  } in
  Alcotest.(check bool) "read-only skips to Pass" true
    (Verifier_oas.verify req = Ok Pass)

let test_hook_continues_on_verify_error () =
  let verify_called = ref false in
  let hook =
    Verifier_oas.make_pre_tool_hook
      ~verify_fn:(fun _req ->
        verify_called := true;
        Error "verifier backend unavailable")
      ~goal:"test goal"
      ~context_summary:"test context"
  in
  let decision =
    hook
      (Oas.Hooks.PreToolUse {
         tool_use_id = "test-id-1";
         tool_name = "keeper_bash";
         input = `Assoc [ ("cmd", `String "echo hi") ];
         accumulated_cost_usd = 0.0;
         turn = 1;
         schedule = { planned_index = 0; batch_index = 0;
                      batch_size = 1; batch_kind = "sequential"; concurrency_class = "default" };
       })
  in
  Alcotest.(check bool) "verify called" true !verify_called;
  Alcotest.(check bool) "verifier errors degrade open"
    true
    (decision = Oas.Hooks.Continue)

let test_hook_readonly_skips_verifier () =
  let verify_called = ref false in
  let hook =
    Verifier_oas.make_pre_tool_hook
      ~verify_fn:(fun _req ->
        verify_called := true;
        Ok (Fail "should not run"))
      ~goal:"test goal"
      ~context_summary:"test context"
  in
  let decision =
    hook
      (Oas.Hooks.PreToolUse {
         tool_use_id = "test-id-2";
         tool_name = "read file";
         input = `Assoc [ ("path", `String "README.md") ];
         accumulated_cost_usd = 0.0;
         turn = 1;
         schedule = { planned_index = 0; batch_index = 0;
                      batch_size = 1; batch_kind = "sequential"; concurrency_class = "default" };
       })
  in
  Alcotest.(check bool) "verify skipped" false !verify_called;
  Alcotest.(check bool) "readonly still continues"
    true
    (decision = Oas.Hooks.Continue)

(* ================================================================ *)
(* Roundtrip: keeper_default_gate_config -> guardrails               *)
(* ================================================================ *)

let test_default_gate_roundtrip () =
  let gate : Masc_mcp.Eval_gate.gate_config =
    { max_cost_usd = 0.10;
      max_tool_calls_per_turn = 5;
      entropy_threshold = 2;
      destructive_check_enabled = true;
      allowlist_enabled = false;
      allowed_tools = [];
      denied_tools = [ "keeper_bash"; "keeper_fs_edit" ];
    }
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  (* Mode removal: allowlist_enabled=false. Safety via denied_tools list.
     eval_gate_to_oas_guardrails produces DenyList when denied_tools is non-empty. *)
  Alcotest.(check bool) "default -> DenyList (safety)"
    true
    (match g.tool_filter with
     | Oas.Guardrails.DenyList names -> List.length names > 0
     | _ -> false);
  Alcotest.(check (option int)) "default max_tool_calls = 5"
    (Some 5) g.max_tool_calls_per_turn

(* ================================================================ *)
(* execution_scope -> gate_config -> guardrails roundtrip             *)
(* ================================================================ *)

let test_observe_only_roundtrip () =
  let gate =
    Worker_oas.gate_config_of_execution_scope
      Worker_types.Observe_only
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "Observe_only -> DenyList (code mutation blocked)"
    true
    (match g.tool_filter with
     | Oas.Guardrails.DenyList names -> List.length names > 0
     | _ -> false);
  Alcotest.(check (option int)) "Observe_only max_calls = 30"
    (Some 30) g.max_tool_calls_per_turn

let test_observe_only_denies_mutating_masc_tools () =
  let gate =
    Worker_oas.gate_config_of_execution_scope
      Worker_types.Observe_only
  in
  List.iter
    (fun name ->
      Alcotest.(check bool) (name ^ " denied in observe_only") true
        (List.mem name gate.denied_tools))
    [
      "masc_worktree_create";
      "masc_worktree_remove";
      "masc_run_init";
      "masc_run_plan";
      "masc_run_log";
      "masc_run_deliverable";
      "masc_board_post";
      "masc_board_comment";
      "masc_board_vote";
    ]

let test_limited_code_change_roundtrip () =
  let gate =
    Worker_oas.gate_config_of_execution_scope
      Worker_types.Limited_code_change
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "Limited -> DenyList"
    true
    (match g.tool_filter with
     | Oas.Guardrails.DenyList names -> List.length names > 0
     | _ -> false)

let test_autonomous_roundtrip () =
  let gate =
    Worker_oas.gate_config_of_execution_scope
      Worker_types.Autonomous
  in
  let g = Verifier_oas.eval_gate_to_oas_guardrails gate in
  Alcotest.(check bool) "Autonomous -> AllowAll"
    true
    (match g.tool_filter with
     | Oas.Guardrails.AllowAll -> true
     | _ -> false);
  Alcotest.(check (option int)) "Autonomous max_calls = 20"
    (Some 20) g.max_tool_calls_per_turn

(* ================================================================ *)
(* Test Suite                                                        *)
(* ================================================================ *)

let () =
  Alcotest.run "verifier_oas_bridge" [
    ("eval_gate_to_oas_guardrails", [
      Alcotest.test_case "allowlist -> AllowList" `Quick
        test_allowlist_maps_to_allowlist;
      Alcotest.test_case "denylist -> DenyList" `Quick
        test_denylist_maps_to_denylist;
      Alcotest.test_case "neither -> AllowAll" `Quick
        test_neither_maps_to_allowall;
      Alcotest.test_case "empty allowlist -> AllowList []" `Quick
        test_empty_allowlist_maps_to_empty_allowlist;
      Alcotest.test_case "max_tool_calls preserved" `Quick
        test_max_tool_calls_preserved;
      Alcotest.test_case "allowlist ignores denied" `Quick
        test_allowlist_ignores_denied_when_both;
    ]);
    ("verdict_to_hook_decision", [
      Alcotest.test_case "Pass -> Continue" `Quick test_pass_to_continue;
      Alcotest.test_case "Warn -> Continue" `Quick test_warn_to_continue;
      Alcotest.test_case "Fail -> Skip" `Quick test_fail_to_skip;
    ]);
    ("read_only_predicate", [
      Alcotest.test_case "read tools" `Quick test_read_tools_are_readonly;
      Alcotest.test_case "write tools" `Quick test_write_tools_are_not_readonly;
    ]);
    ("parse_verdict", [
      Alcotest.test_case "PASS" `Quick test_parse_verdict_pass;
      Alcotest.test_case "PASS with trailing" `Quick
        test_parse_verdict_pass_with_trailing;
      Alcotest.test_case "WARN" `Quick test_parse_verdict_warn;
      Alcotest.test_case "FAIL" `Quick test_parse_verdict_fail;
      Alcotest.test_case "case insensitive" `Quick
        test_parse_verdict_case_insensitive;
      Alcotest.test_case "unknown -> Error" `Quick
        test_parse_verdict_unknown_returns_error;
      Alcotest.test_case "empty -> Error" `Quick
        test_parse_verdict_empty_returns_error;
      Alcotest.test_case "PASSING prefix rejected" `Quick
        test_parse_verdict_rejects_passing_prefix;
      Alcotest.test_case "WARNING prefix rejected" `Quick
        test_parse_verdict_rejects_warning_prefix;
    ]);
    ("verify_skip", [
      Alcotest.test_case "read-only skips" `Quick test_verify_skips_readonly;
      Alcotest.test_case "hook verifier errors degrade open" `Quick
        test_hook_continues_on_verify_error;
      Alcotest.test_case "hook skips verifier for readonly tools" `Quick
        test_hook_readonly_skips_verifier;
    ]);
    ("autonomous_gate roundtrip", [
      Alcotest.test_case "default -> AllowList (strict)" `Quick test_default_gate_roundtrip;
    ]);
    ("execution_scope roundtrip", [
      Alcotest.test_case "Observe_only -> DenyList" `Quick
        test_observe_only_roundtrip;
      Alcotest.test_case "Observe_only denies mutating masc tools" `Quick
        test_observe_only_denies_mutating_masc_tools;
      Alcotest.test_case "Limited -> DenyList" `Quick
        test_limited_code_change_roundtrip;
      Alcotest.test_case "Autonomous -> AllowAll" `Quick
        test_autonomous_roundtrip;
    ]);
  ]
