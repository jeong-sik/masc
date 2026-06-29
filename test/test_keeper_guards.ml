(** Unit tests for [Keeper_guards] — decomposed pre_tool_use chain.

    Verifies:
    - Each guard's decision logic in isolation
    - [compose_all] short-circuits on first non-[Continue]
    - Stateful streak behavior across invocations
    - Utility helpers moved from [Keeper_hooks_oas]
      ([extract_command_from_input], [render_inline_skip_reason]) *)

open Alcotest
module KG = Masc.Keeper_guards
module HK = Masc.Keeper_hooks_oas
module P = Masc.Otel_metric_store
module TT = Agent_sdk.Types

(* ----------------------------------------------------------------- *)
(* Helpers                                                             *)
(* ----------------------------------------------------------------- *)

(** Build a minimal keeper_meta ref for guards that only read [name]. *)
let make_meta_ref (name : string) : Masc.Keeper_meta_contract.keeper_meta ref =
  let json : Yojson.Safe.t = `Assoc [
    ("name", `String name);
    ("agent_name", `String name);
    ("trace_id", `String "keeper-guards-test");
    ("tool_access",
      Json_util.json_string_list
        ([]));
  ] in
  match Masc_test_deps.meta_of_json_fixture json with
  | Ok meta -> ref meta
  | Error e -> failwith ("make_meta_ref: " ^ e)

let pre_tool_use_event
    ~(tool_name : string)
    ?(input = `Assoc [])
    ?(accumulated_cost_usd = 0.0)
    ?(turn = 1)
    ?(batch_index = 0)
    ?(batch_size = 1)
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
      batch_index;
      batch_size;
      concurrency_class = "parallel_read";
      batch_kind = "parallel";
    };
  }

let post_tool_use_event
    ~(tool_name : string)
    ?(input = `Assoc [])
    ?(output = Ok ({ TT.content = {|{"ok":true}|}; _meta = None } : TT.tool_output))
    ()
  : Agent_sdk.Hooks.hook_event =
  Agent_sdk.Hooks.PostToolUse {
    tool_use_id = "toolu_test_" ^ tool_name;
    tool_name;
    input;
    output;
    result_bytes = 2;
    duration_ms = 1.0;
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

let invoke_post_tool_use
    (hooks : Agent_sdk.Hooks.hooks)
    (event : Agent_sdk.Hooks.hook_event)
  : Agent_sdk.Hooks.hook_decision =
  Agent_sdk.Hooks.invoke hooks.post_tool_use event

let decision_kind (d : Agent_sdk.Hooks.hook_decision) : string =
  match d with
  | Continue -> "Continue"
  | Skip -> "Skip"
  | Override _ -> "Override"
  | ApprovalRequired -> "ApprovalRequired"
  | AdjustParams _ -> "AdjustParams"
  | ElicitInput _ -> "ElicitInput"
  | Nudge _ -> "Nudge"
  | HookFailed _ -> "HookFailed"

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
    ~tool_name:"tool_read_file"
    ~reason_code:"streak_gate"
    ~reason_text:"called 5 times"
  in
  check bool "contains tool=tool_read_file" true
    (contains_substring s "tool=tool_read_file");
  check bool "contains code=streak_gate" true
    (contains_substring s "code=streak_gate");
  check bool "contains source=keeper_hook" true
    (contains_substring s "source=keeper_hook");
  let with_source = KG.render_inline_skip_reason_with_source
    ~source_path:"lib/keeper/keeper_guards.ml"
    ~source_line:123
    ~tool_name:"tool_read_file"
    ~reason_code:"streak_gate"
    ~reason_text:"called 5 times"
  in
  check bool "contains source_path" true
    (contains_substring with_source "source_path=lib/keeper/keeper_guards.ml");
  check bool "contains source_line" true
    (contains_substring with_source "source_line=123")

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
  check bool "approval waits without rejection" false
    (KG.gate_decision_is_rejection KG.Gate_approval_required)

let test_gate_rejection_log_severity_splits_repeats () =
  KG.For_testing.reset_gate_rejection_log_counts ();
  Fun.protect
    ~finally:KG.For_testing.reset_gate_rejection_log_counts
    (fun () ->
      let next () =
        KG.For_testing.record_gate_rejection_log_severity
          ~keeper_name:"test_keeper"
          ~stage:"keeper_deny"
          ~tool_name:"dangerous_tool"
          ~reason_code:"keeper_deny"
          ()
      in
      check string "first rejection is warn" "warn"
        (KG.gate_rejection_log_severity_to_string (next ()));
      (match next () with
       | KG.Gate_rejection_repeat_info 2 -> ()
       | severity ->
         failf "expected second rejection info/2, got %s"
           (KG.gate_rejection_log_severity_to_string severity));
      (match next () with
       | KG.Gate_rejection_repeat_debug 3 -> ()
       | severity ->
         failf "expected third rejection debug/3, got %s"
           (KG.gate_rejection_log_severity_to_string severity)))

let test_gate_rejection_log_severity_keys_by_rejection () =
  KG.For_testing.reset_gate_rejection_log_counts ();
  Fun.protect
    ~finally:KG.For_testing.reset_gate_rejection_log_counts
    (fun () ->
      let record ?reason_key ~tool_name () =
        KG.For_testing.record_gate_rejection_log_severity
          ?reason_key
          ~keeper_name:"test_keeper"
          ~stage:"destructive_guard"
          ~tool_name
          ~reason_code:"destructive_guard"
          ()
      in
      let first = record ~reason_key:"rm -rf" ~tool_name:"shell_exec" () in
      let repeat = record ~reason_key:"rm -rf" ~tool_name:"shell_exec" () in
      let different_tool =
        record ~reason_key:"rm -rf" ~tool_name:"tool_execute" ()
      in
      let different_reason =
        record ~reason_key:"chmod 777" ~tool_name:"shell_exec" ()
      in
      check string "first key warns" "warn"
        (KG.gate_rejection_log_severity_to_string first);
      check string "same key repeats as info" "info"
        (KG.gate_rejection_log_severity_to_string repeat);
      check string "different tool has own first warn" "warn"
        (KG.gate_rejection_log_severity_to_string different_tool);
      check string "different reason has own first warn" "warn"
        (KG.gate_rejection_log_severity_to_string different_reason))

let test_gate_rejection_planner_alternative () =
  let streak =
    KG.For_testing.planner_alternative_for_gate
      ~stage:"streak_gate" ~tool_name:"tool_read_file"
  in
  check bool "includes structured field" true
    (contains_substring streak "planner_alternative=");
  check bool "names retry alternative" true
    (contains_substring streak "report no-work/blocker directly");
  let destructive =
    KG.For_testing.planner_alternative_for_gate
      ~stage:"destructive_guard" ~tool_name:"shell_exec"
  in
  check bool "destructive suggests safe command" true
    (contains_substring destructive "safe read-only command")

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
    check string "keeper_name" "test_keeper" event.KG.keeper_name;
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

let test_gate_observer_failure_counts_actual_keeper () =
  let meta_ref = make_meta_ref "keeper_gate_observer_failure" in
  let keeper = (!meta_ref).name in
  let labels = [ ("keeper", keeper); ("site", "gate_observer") ] in
  let before =
    P.metric_value_or_zero Keeper_metrics.(to_string GuardsFailures) ~labels ()
  in
  let on_gate_decision _event =
    raise (Failure "synthetic gate observer failure")
  in
  let hook =
    KG.deny_guard ~meta_ref ~on_gate_decision ~denied:["dangerous_tool"]
  in
  let d = invoke hook (pre_tool_use_event ~tool_name:"dangerous_tool" ()) in
  check string "denied tool still overrides" "Override" (decision_kind d);
  let after =
    P.metric_value_or_zero Keeper_metrics.(to_string GuardsFailures) ~labels ()
  in
  check (float 0.0001) "observer failure counted for keeper"
    (before +. 1.0) after

let test_deny_guard_continues () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.deny_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~denied:["other_tool"]
  in
  let d = invoke hook (pre_tool_use_event ~tool_name:"allowed_tool" ()) in
  check string "allowed tool -> Continue" "Continue" (decision_kind d)

let test_cost_guard_over_limit_continues () =
  let meta_ref = make_meta_ref "test_keeper" in
  let hook =
    KG.cost_guard ~meta_ref ~on_gate_decision:no_gate_observer
      ~max_cost_usd:(Some 0.10)
  in
  let d = invoke hook
    (pre_tool_use_event ~tool_name:"expensive" ~accumulated_cost_usd:0.15 ())
  in
  check string "over advisory threshold -> Continue" "Continue" (decision_kind d)

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

let readonly_observation_hook () =
  let meta_ref = make_meta_ref "test_keeper" in
  let state = KG.make_readonly_observation_state () in
  KG.readonly_observation_duplicate_guard
    ~meta_ref ~on_gate_decision:no_gate_observer ~state

let test_readonly_observation_duplicate_blocks_same_input () =
  let hook = readonly_observation_hook () in
  let input = `Assoc [ ("limit", `Int 15) ] in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "first read-only observation -> Continue"
    "Continue" (decision_kind first);
  let post =
    invoke_post_tool_use hook
      (post_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "successful read-only observation is recorded"
    "Continue" (decision_kind post);
  let second =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "duplicate read-only observation -> Override"
    "Override" (decision_kind second);
  let text = override_text second in
  check bool "override mentions readonly duplicate" true
    (contains_substring text "code=readonly_observation_duplicate")

let test_readonly_observation_duplicate_blocks_pending_same_input () =
  let hook = readonly_observation_hook () in
  let input = `Assoc [ ("limit", `Int 15) ] in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "first pending read-only observation -> Continue"
    "Continue" (decision_kind first);
  let second =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "duplicate pending read-only observation -> Override"
    "Override" (decision_kind second)

let test_readonly_observation_duplicate_drains_pending_on_batch_change () =
  let hook = readonly_observation_hook () in
  let input = `Assoc [ ("limit", `Int 15) ] in
  let first =
    invoke hook
      (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ~batch_index:0
         ~batch_size:2 ())
  in
  check string "first pending read-only observation -> Continue"
    "Continue" (decision_kind first);
  let next_batch =
    invoke hook
      (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ~batch_index:1
         ~batch_size:1 ())
  in
  check string "stale pending state is scoped to one tool batch"
    "Continue" (decision_kind next_batch)

let test_readonly_observation_duplicate_canonicalizes_input_order () =
  let hook = readonly_observation_hook () in
  let first_input =
    `Assoc [ ("limit", `Int 15); ("status", `String "open") ]
  in
  let second_input =
    `Assoc [ ("status", `String "open"); ("limit", `Int 15) ]
  in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input:first_input ())
  in
  check string "first reordered observation -> Continue"
    "Continue" (decision_kind first);
  let post =
    invoke_post_tool_use hook
      (post_tool_use_event ~tool_name:"keeper_tasks_list" ~input:first_input ())
  in
  check string "successful reordered observation is recorded"
    "Continue" (decision_kind post);
  let second =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input:second_input ())
  in
  check string "same object with reordered fields -> Override"
    "Override" (decision_kind second)

let test_readonly_observation_duplicate_preserves_duplicate_key_order () =
  let hook = readonly_observation_hook () in
  let first_input =
    `Assoc [ ("duplicate", `Int 1); ("limit", `Int 15); ("duplicate", `Int 2) ]
  in
  let same_input =
    `Assoc [ ("limit", `Int 15); ("duplicate", `Int 1); ("duplicate", `Int 2) ]
  in
  let different_duplicate_order =
    `Assoc [ ("limit", `Int 15); ("duplicate", `Int 2); ("duplicate", `Int 1) ]
  in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input:first_input ())
  in
  check string "first duplicate-key observation -> Continue"
    "Continue" (decision_kind first);
  let post =
    invoke_post_tool_use hook
      (post_tool_use_event ~tool_name:"keeper_tasks_list" ~input:first_input ())
  in
  check string "successful duplicate-key observation is recorded"
    "Continue" (decision_kind post);
  let same =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input:same_input ())
  in
  check string "same duplicate-key relative order -> Override"
    "Override" (decision_kind same);
  let different =
    invoke hook
      (pre_tool_use_event ~tool_name:"keeper_tasks_list"
         ~input:different_duplicate_order
         ())
  in
  check string "different duplicate-key relative order -> Continue"
    "Continue" (decision_kind different)

let test_readonly_observation_duplicate_allows_different_input () =
  let hook = readonly_observation_hook () in
  let first =
    invoke hook
      (pre_tool_use_event ~tool_name:"keeper_tasks_list"
         ~input:(`Assoc [ ("limit", `Int 15) ])
         ())
  in
  check string "first read-only observation -> Continue"
    "Continue" (decision_kind first);
  let second =
    invoke hook
      (pre_tool_use_event ~tool_name:"keeper_tasks_list"
         ~input:(`Assoc [ ("limit", `Int 20) ])
         ())
  in
  check string "different input -> Continue" "Continue" (decision_kind second)

let test_readonly_observation_duplicate_allows_retry_after_error () =
  let hook = readonly_observation_hook () in
  let input = `Assoc [ ("limit", `Int 15) ] in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "first read-only observation -> Continue"
    "Continue" (decision_kind first);
  let failed_output =
    Error
      ({ TT.message = "transient failure"; recoverable = true; error_class = None }
       : TT.tool_error)
  in
  let post =
    invoke_post_tool_use hook
      (post_tool_use_event ~tool_name:"keeper_tasks_list" ~input ~output:failed_output ())
  in
  check string "failed read-only observation clears pending state"
    "Continue" (decision_kind post);
  let retry =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "same read after failed output -> Continue"
    "Continue" (decision_kind retry)

let test_readonly_observation_duplicate_resets_after_write_tool () =
  let hook = readonly_observation_hook () in
  let input = `Assoc [ ("limit", `Int 15) ] in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "first read-only observation -> Continue"
    "Continue" (decision_kind first);
  let write =
    invoke hook
      (pre_tool_use_event ~tool_name:"masc_keeper_msg_cancel"
         ~input:(`Assoc [ ("request_id", `String "req-1") ])
         ())
  in
  check string "write tool resets observation state"
    "Continue" (decision_kind write);
  let after_write =
    invoke hook (pre_tool_use_event ~tool_name:"keeper_tasks_list" ~input ())
  in
  check string "same read after write -> Continue"
    "Continue" (decision_kind after_write)

let test_readonly_observation_duplicate_exempts_polling_read () =
  let hook = readonly_observation_hook () in
  let input = `Assoc [ ("request_id", `String "req-1") ] in
  let first =
    invoke hook (pre_tool_use_event ~tool_name:"masc_keeper_msg_result" ~input ())
  in
  check string "first poll -> Continue" "Continue" (decision_kind first);
  let second =
    invoke hook (pre_tool_use_event ~tool_name:"masc_keeper_msg_result" ~input ())
  in
  check string "same poll remains allowed" "Continue" (decision_kind second)

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
  with_env "MASC_DISABLE_HITL" "false" (fun () ->
    let meta_ref = make_meta_ref "test_keeper" in
    let observed = ref [] in
    let on_gate_decision event = observed := event :: !observed in
    let hook = KG.governance_approval_guard ~meta_ref ~on_gate_decision in
    let d =
      invoke hook
        (pre_tool_use_event ~tool_name:"tool_edit_file"
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
      check string "tool_name" "tool_edit_file" event.KG.tool_name;
      check (option string) "source_path"
        (Some "lib/keeper/keeper_guards.ml")
        event.KG.source_path;
      check bool "source_line present" true
        (match event.KG.source_line with
         | Some line -> line > 0
         | None -> false)
    | events ->
      failf "expected one observer event, got %d" (List.length events)))

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
  (* The reason should be from deny_guard. Cost telemetry never overrides. *)
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
    test_case "gate decision vocabulary" `Quick test_gate_decision_vocabulary;
    test_case "gate rejection log severity splits repeats" `Quick
      test_gate_rejection_log_severity_splits_repeats;
    test_case "gate rejection log severity keys by rejection" `Quick
      test_gate_rejection_log_severity_keys_by_rejection;
    test_case "gate rejection planner alternative" `Quick
      test_gate_rejection_planner_alternative;
  ];
  "deny_guard", [
    test_case "blocks denied tool" `Quick test_deny_guard_blocks;
    test_case "notifies observer on block" `Quick
      test_deny_guard_notifies_gate_observer;
    test_case "observer failure counts actual keeper" `Quick
      test_gate_observer_failure_counts_actual_keeper;
    test_case "continues for allowed tool" `Quick test_deny_guard_continues;
  ];
  "cost_guard", [
    test_case "continues over advisory threshold" `Quick
      test_cost_guard_over_limit_continues;
    test_case "continues under limit" `Quick test_cost_guard_under_limit;
    test_case "no budget -> continue" `Quick test_cost_guard_disabled;
  ];
  "streak_guard", [
    test_case "under threshold -> continue" `Quick test_streak_guard_under_threshold;
    test_case "at threshold -> override" `Quick test_streak_guard_at_threshold;
    test_case "resets on different tool" `Quick test_streak_guard_resets_on_different_tool;
    test_case "manual state reset" `Quick test_streak_state_manual_reset;
  ];
  "readonly_observation_duplicate_guard", [
    test_case "blocks same read-only input" `Quick
      test_readonly_observation_duplicate_blocks_same_input;
    test_case "blocks same pending read-only input" `Quick
      test_readonly_observation_duplicate_blocks_pending_same_input;
    test_case "drains pending on batch change" `Quick
      test_readonly_observation_duplicate_drains_pending_on_batch_change;
    test_case "canonicalizes input object order" `Quick
      test_readonly_observation_duplicate_canonicalizes_input_order;
    test_case "preserves duplicate key order" `Quick
      test_readonly_observation_duplicate_preserves_duplicate_key_order;
    test_case "allows different input" `Quick
      test_readonly_observation_duplicate_allows_different_input;
    test_case "allows retry after errored output" `Quick
      test_readonly_observation_duplicate_allows_retry_after_error;
    test_case "resets after write tool" `Quick
      test_readonly_observation_duplicate_resets_after_write_tool;
    test_case "exempts polling reads" `Quick
      test_readonly_observation_duplicate_exempts_polling_read;
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
