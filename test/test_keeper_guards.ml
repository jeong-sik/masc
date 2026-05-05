(** Unit tests for [Keeper_guards] — decomposed pre_tool_use chain.

    Verifies:
    - Each guard's decision logic in isolation
    - [compose_all] short-circuits on first non-[Continue]
    - Stateful streak behavior across invocations
    - Utility helpers moved from [Keeper_hooks_oas]
      ([extract_command_from_input], [render_inline_skip_reason]) *)

open Alcotest
module KG = Masc_mcp.Keeper_guards
module HK = Masc_mcp.Keeper_hooks_oas

(* ----------------------------------------------------------------- *)
(* Helpers                                                             *)
(* ----------------------------------------------------------------- *)

(** Build a minimal keeper_meta ref for guards that only read [name]. *)
let make_meta_ref (name : string) : Masc_mcp.Keeper_types.keeper_meta ref =
  let json : Yojson.Safe.t = `Assoc [
    ("name", `String name);
    ("agent_name", `String name);
    ("trace_id", `String "keeper-guards-test");
    ("tool_access",
      Masc_mcp.Keeper_types.tool_access_to_json
        (Masc_mcp.Keeper_types.Preset
           { preset = Masc_mcp.Keeper_types.Full; also_allow = [] }));
  ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> ref meta
  | Error e -> failwith ("make_meta_ref: " ^ e)

let pre_tool_use_event
    ~(tool_name : string)
    ?(input = `Assoc [])
    ?(accumulated_cost_usd = 0.0)
    ?(turn = 1)
    ()
  : Agent_sdk.Hooks.hook_event =
  Agent_sdk.Hooks.PreToolUse {
    tool_use_id = "toolu_test_" ^ tool_name;
    tool_name;
    input;
    accumulated_cost_usd;
    turn;
    schedule = {
      planned_index = 0;
      batch_index = 0;
      batch_size = 1;
      concurrency_class = "parallel_read";
      batch_kind = "parallel";
    };
  }

let invoke (hooks : Agent_sdk.Hooks.hooks) (event : Agent_sdk.Hooks.hook_event)
  : Agent_sdk.Hooks.hook_decision =
  Agent_sdk.Hooks.invoke hooks.pre_tool_use event

let decision_kind (d : Agent_sdk.Hooks.hook_decision) : string =
  match d with
  | Continue -> "Continue"
  | Skip -> "Skip"
  | Override _ -> "Override"
  | ApprovalRequired -> "ApprovalRequired"
  | AdjustParams _ -> "AdjustParams"
  | ElicitInput _ -> "ElicitInput"
  | Nudge _ -> "Nudge"

let override_text (d : Agent_sdk.Hooks.hook_decision) : string =
  match d with
  | Override s -> s
  | _ -> failwith ("expected Override, got " ^ decision_kind d)

let no_gate_observer = KG.ignore_gate_decision

(* ----------------------------------------------------------------- *)
(* Utility tests                                                      *)
(* ----------------------------------------------------------------- *)

let test_extract_command_from_input () =
  let j1 = `Assoc [("command", `String "ls -la")] in
  check string "command key" "ls -la" (KG.extract_command_from_input j1);
  let j2 = `Assoc [("cmd", `String "git status")] in
  check string "cmd key" "git status" (KG.extract_command_from_input j2);
  let j3 = `Assoc [("content", `String "hello")] in
  check string "content key" "hello" (KG.extract_command_from_input j3);
  let j4 = `Assoc [] in
  check string "empty" "" (KG.extract_command_from_input j4)

let contains_substring (haystack : string) (needle : string) : bool =
  try
    let _ = Str.search_forward (Str.regexp_string needle) haystack 0 in
    true
  with Not_found -> false

let with_env name value f =
  let old = Sys.getenv_opt name in
  Unix.putenv name value;
  Fun.protect
    ~finally:(fun () ->
      match old with
      | Some old_value -> Unix.putenv name old_value
      | None -> Unix.putenv name "")
    f

let test_render_inline_skip_reason () =
  let s = KG.render_inline_skip_reason
    ~tool_name:"keeper_fs_read"
    ~reason_code:"streak_gate"
    ~reason_text:"called 5 times"
  in
  check bool "contains tool=keeper_fs_read" true
    (contains_substring s "tool=keeper_fs_read");
  check bool "contains code=streak_gate" true
    (contains_substring s "code=streak_gate");
  check bool "contains source=keeper_hook" true
    (contains_substring s "source=keeper_hook");
  let with_source = KG.render_inline_skip_reason_with_source
    ~source_path:"lib/keeper/keeper_guards.ml"
    ~source_line:123
    ~tool_name:"keeper_fs_read"
    ~reason_code:"streak_gate"
    ~reason_text:"called 5 times"
  in
  check bool "contains source_path" true
    (contains_substring with_source "source_path=lib/keeper/keeper_guards.ml");
  check bool "contains source_line" true
    (contains_substring with_source "source_line=123")

let make_gate_event ?(decision = KG.Gate_override) () =
  { KG.stage = "keeper_deny";
    decision;
    reason_code = "keeper_deny";
    reason_text = "tool is on the keeper deny list";
    tool_name = "dangerous_tool";
    input = `Assoc [];
    turn = 4;
    accumulated_cost_usd = 0.0;
    stage_latency_ms = 1.0;
    source_path = Some "lib/keeper/keeper_guards.ml";
    source_line = Some 123;
  }

let test_render_pre_tool_gate_output_preserves_source () =
  let blocked = HK.render_pre_tool_gate_output (make_gate_event ()) in
  check bool "override output carries source path" true
    (contains_substring blocked "source_path=lib/keeper/keeper_guards.ml");
  check bool "override output carries source line" true
    (contains_substring blocked "source_line=123");
  let approval =
    HK.render_pre_tool_gate_output
      (make_gate_event ~decision:KG.Gate_approval_required ())
  in
  check bool "approval output carries source path" true
    (contains_substring approval "source_path=lib/keeper/keeper_guards.ml");
  check bool "approval output carries source line" true
    (contains_substring approval "source_line=123")

let test_gate_decision_vocabulary () =
  check string "override" "override"
    (KG.gate_decision_to_string KG.Gate_override);
  check string "continue" "continue"
    (KG.gate_decision_to_string KG.Gate_continue);
  check string "approval_required" "approval_required"
    (KG.gate_decision_to_string KG.Gate_approval_required);
  check bool "override rejects" true
    (KG.gate_decision_is_rejection KG.Gate_override);
  check bool "continue does not reject" false
    (KG.gate_decision_is_rejection KG.Gate_continue);
  check bool "approval rejects" true
    (KG.gate_decision_is_rejection KG.Gate_approval_required)

(* ----------------------------------------------------------------- *)
(* Individual guard tests                                              *)
(* ----------------------------------------------------------------- *)

let test_deny_guard_blocks () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.deny_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~denied:["dangerous_tool"]
  in
  let d = invoke hook (pre_tool_use_event ~tool_name:"dangerous_tool" ()) in
  check string "denied tool -> Override" "Override" (decision_kind d);
  let text = override_text d in
  check bool "override mentions deny list" true
    (contains_substring text "code=keeper_deny");
  check bool "override carries source path" true
    (contains_substring text "source_path=lib/keeper/keeper_guards.ml");
  check bool "override carries source line" true
    (contains_substring text "source_line=")

let test_deny_guard_notifies_gate_observer () =
  let meta_ref = make_meta_ref "test_keeper" in
  let observed = ref [] in
  let on_gate_decision event = observed := event :: !observed in
  let hook =
    KG.deny_guard ~meta_ref ~on_gate_decision ~denied:["dangerous_tool"]
  in
  let d =
    invoke hook
      (pre_tool_use_event ~tool_name:"dangerous_tool"
         ~input:(`Assoc [ ("path", `String "/tmp/secret") ])
         ~turn:4 ())
  in
  check string "denied tool -> Override" "Override" (decision_kind d);
  match !observed with
  | [ event ] ->
    check string "stage" "keeper_deny" event.KG.stage;
    check string "decision" "override"
      (KG.gate_decision_to_string event.KG.decision);
    check string "reason_code" "keeper_deny" event.KG.reason_code;
    check string "tool_name" "dangerous_tool" event.KG.tool_name;
    check int "turn" 4 event.KG.turn;
    check (option string) "source_path"
      (Some "lib/keeper/keeper_guards.ml")
      event.KG.source_path;
    check bool "source_line present" true
      (match event.KG.source_line with
       | Some line -> line > 0
       | None -> false);
    check bool "input preserved" true
      (match event.KG.input with
       | `Assoc [ ("path", `String "/tmp/secret") ] -> true
       | _ -> false)
  | events ->
    failf "expected one observer event, got %d" (List.length events)

let test_deny_guard_continues () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.deny_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~denied:["other_tool"]
  in
  let d = invoke hook (pre_tool_use_event ~tool_name:"allowed_tool" ()) in
  check string "allowed tool -> Continue" "Continue" (decision_kind d)

let test_cost_guard_blocks () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:(Some 0.10)
  in
  let d = invoke hook
    (pre_tool_use_event ~tool_name:"expensive" ~accumulated_cost_usd:0.15 ())
  in
  check string "over limit -> Override" "Override" (decision_kind d)

let test_cost_guard_under_limit () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:(Some 0.10)
  in
  let d = invoke hook
    (pre_tool_use_event ~tool_name:"cheap" ~accumulated_cost_usd:0.05 ())
  in
  check string "under limit -> Continue" "Continue" (decision_kind d)

let test_cost_guard_disabled () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:None
  in
  let d = invoke hook
    (pre_tool_use_event ~tool_name:"any" ~accumulated_cost_usd:999.0 ())
  in
  check string "no budget -> Continue" "Continue" (decision_kind d)

let test_streak_guard_under_threshold () =
  let meta_ref = make_meta_ref "test_keeper" in
  let state = KG.make_streak_state () in
  let hook =
    KG.streak_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~state ~threshold:5
  in
  (* 4 consecutive calls — should all Continue *)
  for _ = 1 to 4 do
    let d = invoke hook (pre_tool_use_event ~tool_name:"repeat_me" ()) in
    check string "under threshold -> Continue" "Continue" (decision_kind d)
  done

let test_streak_guard_at_threshold () =
  let meta_ref = make_meta_ref "test_keeper" in
  let state = KG.make_streak_state () in
  let hook =
    KG.streak_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~state ~threshold:5
  in
  (* 4 calls Continue, 5th blocks *)
  for _ = 1 to 4 do
    let _ = invoke hook (pre_tool_use_event ~tool_name:"repeat_me" ()) in
    ()
  done;
  let d = invoke hook (pre_tool_use_event ~tool_name:"repeat_me" ()) in
  check string "5th consecutive -> Override" "Override" (decision_kind d);
  let text = override_text d in
  check bool "override mentions streak_gate" true
    (contains_substring text "code=streak_gate")

let test_streak_guard_resets_on_different_tool () =
  let meta_ref = make_meta_ref "test_keeper" in
  let state = KG.make_streak_state () in
  let hook =
    KG.streak_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~state ~threshold:3
  in
  (* 2 calls of tool_a, then tool_b resets counter *)
  let _ = invoke hook (pre_tool_use_event ~tool_name:"tool_a" ()) in
  let _ = invoke hook (pre_tool_use_event ~tool_name:"tool_a" ()) in
  let d_b = invoke hook (pre_tool_use_event ~tool_name:"tool_b" ()) in
  check string "different tool -> Continue" "Continue" (decision_kind d_b);
  (* tool_a counter was reset, so another 2 calls won't trigger *)
  let _ = invoke hook (pre_tool_use_event ~tool_name:"tool_a" ()) in
  let d_back = invoke hook (pre_tool_use_event ~tool_name:"tool_a" ()) in
  check string "reset streak -> Continue" "Continue" (decision_kind d_back)

let test_streak_state_manual_reset () =
  let meta_ref = make_meta_ref "test_keeper" in
  let state = KG.make_streak_state () in
  let hook =
    KG.streak_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~state ~threshold:3
  in
  let _ = invoke hook (pre_tool_use_event ~tool_name:"t" ()) in
  let _ = invoke hook (pre_tool_use_event ~tool_name:"t" ()) in
  (* Emulate after_turn reset: streak_state.entry <- ("", 0) *)
  state.entry <- ("", 0);
  let d = invoke hook (pre_tool_use_event ~tool_name:"t" ()) in
  check string "after reset -> Continue" "Continue" (decision_kind d)

let test_custom_guard_blocks () =
  let meta_ref = make_meta_ref "test_keeper" in
  let guard ~tool_name ~input:_ =
    if tool_name = "bad" then Some "user blocked" else None
  in
  let hook =
    KG.custom_guard ~meta_ref ~on_gate_decision:no_gate_observer ~guard
  in
  let d = invoke hook (pre_tool_use_event ~tool_name:"bad" ()) in
  check string "custom blocked -> Override" "Override" (decision_kind d)

let test_custom_guard_passthrough () =
  let meta_ref = make_meta_ref "test_keeper" in
  let guard ~tool_name:_ ~input:_ = None in
  let hook =
    KG.custom_guard ~meta_ref ~on_gate_decision:no_gate_observer ~guard
  in
  let d = invoke hook (pre_tool_use_event ~tool_name:"ok" ()) in
  check string "custom None -> Continue" "Continue" (decision_kind d)

let test_governance_approval_notifies_gate_observer () =
  with_env "MASC_GOVERNANCE_LEVEL" "production" (fun () ->
    let meta_ref = make_meta_ref "test_keeper" in
    let observed = ref [] in
    let on_gate_decision event = observed := event :: !observed in
    let hook = KG.governance_approval_guard ~meta_ref ~on_gate_decision in
    let d =
      invoke hook
        (pre_tool_use_event ~tool_name:"keeper_fs_edit"
           ~input:(`Assoc [ ("path", `String "/tmp/file"); ("content", `String "x") ])
           ())
    in
    check string "high-risk tool -> ApprovalRequired"
      "ApprovalRequired" (decision_kind d);
    match !observed with
    | [ event ] ->
      check string "stage" "governance_approval" event.KG.stage;
      check string "decision" "approval_required"
        (KG.gate_decision_to_string event.KG.decision);
      check string "reason_code" "governance_approval" event.KG.reason_code;
      check string "tool_name" "keeper_fs_edit" event.KG.tool_name;
      check (option string) "source_path"
        (Some "lib/keeper/keeper_guards.ml")
        event.KG.source_path;
      check bool "source_line present" true
        (match event.KG.source_line with
         | Some line -> line > 0
         | None -> false)
    | events ->
      failf "expected one observer event, got %d" (List.length events))

let test_timing_guard_sets_time_and_continues () =
  let tool_start_time = ref 0.0 in
  let hook = KG.timing_guard ~tool_start_time in
  let t_before = !tool_start_time in
  let d = invoke hook (pre_tool_use_event ~tool_name:"any" ()) in
  check string "timing_guard -> Continue" "Continue" (decision_kind d);
  check bool "tool_start_time updated" true (!tool_start_time > t_before)

(* ----------------------------------------------------------------- *)
(* Composition tests                                                   *)
(* ----------------------------------------------------------------- *)

let test_compose_all_empty () =
  let hooks = KG.compose_all [] in
  let d = invoke hooks (pre_tool_use_event ~tool_name:"any" ()) in
  check string "empty compose -> Continue" "Continue" (decision_kind d)

let test_compose_all_continue_all () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hooks = KG.compose_all [
    KG.deny_guard ~meta_ref ~on_gate_decision:no_gate_observer ~denied:[];
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:None;
  ] in
  let d = invoke hooks (pre_tool_use_event ~tool_name:"anything" ()) in
  check string "all Continue -> Continue" "Continue" (decision_kind d)

let test_compose_all_short_circuits_at_first_override () =
  let meta_ref = make_meta_ref "test_keeper" in
  (* deny_guard blocks first -> cost_guard should not fire *)
  let hooks = KG.compose_all [
    KG.deny_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~denied:["blocked_tool"];
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:(Some 0.10);
  ] in
  let d = invoke hooks
    (pre_tool_use_event ~tool_name:"blocked_tool"
       ~accumulated_cost_usd:999.0 ())
  in
  check string "first Override wins" "Override" (decision_kind d);
  let text = override_text d in
  (* The reason should be from deny_guard, not cost_gate *)
  check bool "short-circuit preserves first reason" true
    (contains_substring text "code=keeper_deny")

let test_compose_all_preserves_order () =
  let meta_ref = make_meta_ref "test_keeper" in
  let streak_state = KG.make_streak_state () in
  (* streak_guard fires first; after 3 calls it blocks before reaching cost_guard *)
  let hooks = KG.compose_all [
    KG.streak_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~state:streak_state ~threshold:3;
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:(Some 0.10);
  ] in
  let _ = invoke hooks (pre_tool_use_event ~tool_name:"x"
                          ~accumulated_cost_usd:0.05 ()) in
  let _ = invoke hooks (pre_tool_use_event ~tool_name:"x"
                          ~accumulated_cost_usd:0.05 ()) in
  let d = invoke hooks
    (pre_tool_use_event ~tool_name:"x" ~accumulated_cost_usd:0.05 ())
  in
  (* streak triggered, cost would not have *)
  check string "streak blocks before cost" "Override" (decision_kind d);
  let text = override_text d in
  check bool "reason is streak, not cost" true
    (contains_substring text "code=streak_gate")

(* ----------------------------------------------------------------- *)
(* hooks_of_pre_tool_use                                              *)
(* ----------------------------------------------------------------- *)

let test_hooks_of_pre_tool_use_slots () =
  let hooks =
    KG.hooks_of_pre_tool_use (fun _ -> Agent_sdk.Hooks.Continue)
  in
  check bool "pre_tool_use is Some" true (Option.is_some hooks.pre_tool_use);
  check bool "after_turn is None" true (Option.is_none hooks.after_turn);
  check bool "on_idle is None" true (Option.is_none hooks.on_idle);
  check bool "post_tool_use is None" true (Option.is_none hooks.post_tool_use)

(* ----------------------------------------------------------------- *)
(* Suite                                                               *)
(* ----------------------------------------------------------------- *)

let () = run "Keeper_guards" [
  "utilities", [
    test_case "extract_command_from_input" `Quick test_extract_command_from_input;
    test_case "render_inline_skip_reason" `Quick test_render_inline_skip_reason;
    test_case "pre-tool gate output preserves source" `Quick
      test_render_pre_tool_gate_output_preserves_source;
    test_case "gate decision vocabulary" `Quick test_gate_decision_vocabulary;
  ];
  "deny_guard", [
    test_case "blocks denied tool" `Quick test_deny_guard_blocks;
    test_case "notifies observer on block" `Quick
      test_deny_guard_notifies_gate_observer;
    test_case "continues for allowed tool" `Quick test_deny_guard_continues;
  ];
  "cost_guard", [
    test_case "blocks over limit" `Quick test_cost_guard_blocks;
    test_case "continues under limit" `Quick test_cost_guard_under_limit;
    test_case "no budget -> continue" `Quick test_cost_guard_disabled;
  ];
  "streak_guard", [
    test_case "under threshold -> continue" `Quick test_streak_guard_under_threshold;
    test_case "at threshold -> override" `Quick test_streak_guard_at_threshold;
    test_case "resets on different tool" `Quick test_streak_guard_resets_on_different_tool;
    test_case "manual state reset" `Quick test_streak_state_manual_reset;
  ];
  "custom_guard", [
    test_case "user blocks" `Quick test_custom_guard_blocks;
    test_case "user passes through" `Quick test_custom_guard_passthrough;
  ];
  "governance_approval_guard", [
    test_case "notifies observer on approval required" `Quick
      test_governance_approval_notifies_gate_observer;
  ];
  "timing_guard", [
    test_case "sets time and continues" `Quick test_timing_guard_sets_time_and_continues;
  ];
  "compose_all", [
    test_case "empty compose" `Quick test_compose_all_empty;
    test_case "all Continue" `Quick test_compose_all_continue_all;
    test_case "short-circuits at first Override" `Quick
      test_compose_all_short_circuits_at_first_override;
    test_case "preserves declared order" `Quick test_compose_all_preserves_order;
  ];
  "slot_helpers", [
    test_case "hooks_of_pre_tool_use only fills pre_tool_use" `Quick
      test_hooks_of_pre_tool_use_slots;
  ];
]
