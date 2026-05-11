(* Tests for keeper_execution_receipt operator_disposition / broadcast hook
   (#fleet-stall 2026-04-26).

   Verifies that the silent-dead-end fix in
   [Keeper_execution_receipt.append] classifies pause/exhausted/unknown
   states as broadcast-worthy, while healthy/forward-progress states do
   not trigger an operator broadcast. The end-to-end Activity_graph emit
   path is exercised by the integration smoke (Step 5 part 2). *)

open Alcotest

module R = Masc_mcp.Keeper_execution_receipt
module U = Yojson.Safe.Util

let mk_tool_surface ?(tool_requirement = Masc_mcp.Keeper_agent_tool_surface.Required)
    ?(required_tools = []) ?(missing_required_tools = []) () :
    R.tool_surface =
  {
    (* WORKAROUND: previously "unified" — invalid string never emitted
       by producer.  Typed enum now forces a valid value.
       Root: closed sum type rejects ad-hoc fixture strings. *)
    turn_lane = Masc_mcp.Keeper_agent_tool_surface.Lane_tool_required;
    (* WORKAROUND: previously "post_dispatch" — a string the producer
       never emits.  Typed enum forces a real value; Surface_mixed
       matches the prior test intent of a tool-using turn.
       Root: closed sum type now disallows ad-hoc fixture strings. *)
    tool_surface_class = Masc_mcp.Keeper_agent_tool_surface.Surface_mixed;
    tool_requirement;
    visible_tool_count = 1;
    tool_gate_enabled = true;
    tool_surface_fallback_used = false;
    required_tools;
    missing_required_tools;
  }

let mk_receipt
    ?(outcome : R.outcome_kind = `Error)
    ?(terminal_reason_code = "")
    ?(tool_contract_result = "satisfied")
    ?(tools_used = [ "Read" ])
    ?(observed_tools = [])
    ?(canonical_tools = [])
    ?(reported_tools = [])
    ?(requested_tools = [])
    ?(required_tools = [])
    ?(missing_required_tools = [])
    ?(tool_requirement = Masc_mcp.Keeper_agent_tool_surface.Required)
    ?(cascade_outcome = "completed")
    ?current_task_id
    ?stop_reason
    ?(goal_ids = [])
    ?(error_kind = None)
    ?(error_message = None)
    ?(degraded_retry_applied = false)
    ?(cascade_fallback_applied = false)
    () : R.t =
  {
    keeper_name = "test-keeper";
    agent_name = "test-agent";
    trace_id = "trace-test";
    generation = 1;
    turn_count = Some 1;
    current_task_id;
    goal_ids;
    outcome;
    terminal_reason_code;
    response_text_present = true;
    model_used = None;
    requested_tools;
    reported_tools;
    observed_tools;
    canonical_tools;
    unexpected_tools = [];
    tools_used;
    tool_contract_result;
    tool_surface =
      mk_tool_surface ~tool_requirement ~required_tools ~missing_required_tools ();
    sandbox_kind = Masc_mcp.Keeper_types.Local;
    sandbox_root = None;
    network_mode = Masc_mcp.Keeper_types.Network_none;
    approval_profile = None;
    approval_profile_derived = false;
    cascade_name = R.cascade_name_of_string "default";
    cascade_selected_model = None;
    cascade_attempt_count = 1;
    cascade_fallback_applied;
    cascade_outcome;
    degraded_retry_applied;
    degraded_retry_cascade = None;
    fallback_reason = None;
    cascade_rotation_attempts = [];
    stop_reason;
    error_kind;
    error_message;
    started_at = "2026-04-26T00:00:00Z";
    ended_at = "2026-04-26T00:00:01Z";
  }

let check_disp label receipt expected_disp expected_reason =
  let disp, reason = R.operator_disposition receipt in
  check string (label ^ " (disposition)") expected_disp disp;
  check string (label ^ " (reason)") expected_reason reason

(* === Bug class: tool_contract_result violations must pause_human ====== *)

let violation_variants =
  [
    "violated";
    "unknown";
    "needs_execution_progress";
    "missing_required_tool_use";
    "passive_only";
    "claim_only_after_owned_task";
    "tool_surface_mismatch";
    "no_tool_capable_provider";
  ]

let test_pause_human_for_each_violation () =
  List.iter
    (fun v ->
      let r = mk_receipt ~tool_contract_result:v () in
      check_disp ("violation:" ^ v) r "pause_human"
        "tool_required_unsatisfied")
    violation_variants

let test_pause_human_when_no_tools_used () =
  let r = mk_receipt ~tools_used:[] () in
  check_disp "tools_used=[]" r "pause_human" "tool_required_unsatisfied"

(* Regression: the completion-contract layer can report
   [terminal_reason="completion_contract_violation:require_tool_use"] while
   the earlier tool_contract classifier reports
   [tool_contract_result="satisfied_completion"]. Before this branch the
   two-layer disagreement fell through to ("unknown","unmapped_cascade_state")
   and tripped the #11651 regression counter. The terminal_reason is
   authoritative — pause_human/tool_required_unsatisfied. *)
let test_pause_human_for_completion_contract_violation_with_satisfied_inner () =
  let r =
    mk_receipt
      ~terminal_reason_code:"completion_contract_violation:require_tool_use"
      ~tool_contract_result:"satisfied_completion"
      ~error_kind:(Some (R.error_kind_of_string "agent"))
      ~tools_used:[ "keeper_board_list"; "keeper_stay_silent" ]
      ()
  in
  check_disp "completion_contract_violation overrides satisfied inner" r
    "pause_human" "tool_required_unsatisfied"

let test_pause_human_for_completion_contract_violation_other_subclause () =
  let r =
    mk_receipt
      ~terminal_reason_code:"completion_contract_violation:other_subclause"
      ~tool_contract_result:"satisfied"
      ~tools_used:[ "Read" ] ()
  in
  check_disp "completion_contract_violation:other_subclause" r "pause_human"
    "tool_required_unsatisfied"

let test_provider_failure_not_reported_as_tool_unsatisfied () =
  let r =
    mk_receipt ~tools_used:[] ~terminal_reason_code:"api_error_invalid_request"
      ~error_kind:(Some (R.error_kind_of_string "api"))
      ~error_message:
        (Some
           "Invalid request: kimi_cli startup crash while setting process title")
      ()
  in
  check_disp "provider failure before tool use" r "pause_human"
    "provider_runtime_error"

let test_preflight_config_failure_not_reported_as_tool_unsatisfied () =
  let r =
    mk_receipt ~tools_used:[] ~terminal_reason_code:"config_error"
      ~error_kind:(Some (R.error_kind_of_string "config"))
      ~error_message:(Some "provider auth/config failed before turn")
      ()
  in
  check_disp "preflight config before tool use" r "pause_human"
    "preflight_config_error"

(* === Cascade exhausted always alerts ================================ *)

let test_alert_for_cascade_exhausted () =
  let r =
    mk_receipt ~terminal_reason_code:"cascade_exhausted"
      ~cascade_outcome:"exhausted" ()
  in
  check_disp "cascade_exhausted" r "alert_exhausted" "cascade_exhausted"

(* === Unknown / unmapped state must NOT silently look healthy ========= *)

let test_unknown_when_unmapped () =
  let r =
    mk_receipt ~outcome:`Ok ~cascade_outcome:"weird"
      ~tool_contract_result:"satisfied" ()
  in
  check_disp "unmapped" r "unknown" "unmapped_cascade_state"

(* === Forward-progress states do NOT broadcast ======================== *)

let test_pass_for_healthy () =
  let r =
    mk_receipt ~outcome:`Ok ~cascade_outcome:"completed"
      ~tool_contract_result:"satisfied" ~terminal_reason_code:"completed"
      ()
  in
  check_disp "healthy" r "pass" "healthy"

let test_pass_next_for_cascade_fallback () =
  let r =
    mk_receipt ~cascade_fallback_applied:true
      ~cascade_outcome:"passed_to_next_model"
      ~tool_contract_result:"satisfied" ()
  in
  check_disp "cascade_fallback" r "pass_next_model" "cascade_fallback"

let test_fail_open_for_degraded_retry () =
  let r =
    mk_receipt ~degraded_retry_applied:true
      ~tool_contract_result:"satisfied" ()
  in
  check_disp "degraded_retry" r "fail_open_next_cascade" "degraded_retry"

(* === Trigger predicate ============================================== *)

let test_needs_broadcast_predicate () =
  check bool "pause_human triggers" true (R.needs_operator_broadcast "pause_human");
  check bool "alert_exhausted triggers" true
    (R.needs_operator_broadcast "alert_exhausted");
  check bool "unknown triggers" true (R.needs_operator_broadcast "unknown");
  check bool "pass does not" false (R.needs_operator_broadcast "pass");
  check bool "pass_next_model does not" false
    (R.needs_operator_broadcast "pass_next_model");
  check bool "fail_open_next_cascade does not" false
    (R.needs_operator_broadcast "fail_open_next_cascade")

(* === Symmetric coverage: each broadcast disposition is reachable ===== *)

let test_each_broadcast_disp_is_reachable () =
  (* pause_human via violation *)
  let r1 = mk_receipt ~tool_contract_result:"violated" () in
  let d1, _ = R.operator_disposition r1 in
  check bool "pause_human reachable" true (R.needs_operator_broadcast d1);
  (* alert_exhausted via cascade_outcome *)
  let r2 = mk_receipt ~cascade_outcome:"cascade_exhausted" () in
  let d2, _ = R.operator_disposition r2 in
  check bool "alert_exhausted reachable" true (R.needs_operator_broadcast d2);
  (* unknown via unmapped *)
  let r3 =
    mk_receipt ~outcome:`Ok ~cascade_outcome:"weird"
      ~tool_contract_result:"satisfied" ()
  in
  let d3, _ = R.operator_disposition r3 in
  check bool "unknown reachable" true (R.needs_operator_broadcast d3)

let string_list_member name json =
  json |> U.member name |> U.to_list |> List.map U.to_string

let test_broadcast_payload_carries_turn_diagnostics () =
  let receipt =
    mk_receipt
      ~terminal_reason_code:"completion_contract_violation:require_tool_use"
      ~tool_contract_result:"missing_required_tool_use"
      ~tools_used:[ "keeper_tasks_list"; "keeper_stay_silent" ]
      ~observed_tools:[ "keeper_tasks_list"; "keeper_stay_silent" ]
      ~required_tools:[ "keeper_shell"; "masc_worktree_create" ]
      ~missing_required_tools:[ "keeper_shell" ]
      ~current_task_id:"task-102"
      ~stop_reason:Masc_mcp.Cascade_runner.Completed
      ~goal_ids:[ "goal-main" ]
      ()
  in
  let payload =
    R.operator_broadcast_payload receipt ~disposition:"pause_human"
      ~reason:"tool_required_unsatisfied"
  in
  check string "task id" "task-102"
    (payload |> U.member "current_task_id" |> U.to_string);
  check string "last tool" "keeper_stay_silent"
    (payload |> U.member "last_tool_name" |> U.to_string);
  check (list string) "goal ids" [ "goal-main" ]
    (string_list_member "goal_ids" payload);
  check (list string) "tools used"
    [ "keeper_tasks_list"; "keeper_stay_silent" ]
    (string_list_member "tools_used" payload);
  let contract = payload |> U.member "tool_contract" in
  check string "contract result" "missing_required_tool_use"
    (contract |> U.member "result" |> U.to_string);
  check (list string) "required tools"
    [ "keeper_shell"; "masc_worktree_create" ]
    (string_list_member "required_tools" contract);
  check (list string) "missing required tools" [ "keeper_shell" ]
    (string_list_member "missing_required_tools" contract);
  check string "stop reason" "completed"
    (payload |> U.member "stop_reason" |> U.to_string)

let test_stale_broadcast_payload_uses_low_cardinality_stale_reason () =
  let payload =
    R.stale_broadcast_payload
      ~keeper_name:"executor"
      ~agent_name:"executor-agent"
      ~cascade_name:(R.cascade_name_of_string "tier_fast")
      ~trace_id:"trace-stale"
      ~generation:7
      ~failure_reason:None
      ~stale_seconds:629.0
      ~last_turn_ts:1777990000.0
  in
  check string "disposition reason" "stale_turn_timeout"
    (payload |> U.member "disposition_reason" |> U.to_string);
  check string "terminal reason" "stale_turn_timeout"
    (payload |> U.member "terminal_reason_code" |> U.to_string);
  check string "failure cohort" "stale_turn_timeout"
    (payload |> U.member "failure_reason_cohort" |> U.to_string);
  check string "stale bucket" "stale_turn_10m_to_30m"
    (payload |> U.member "stale_turn_bucket" |> U.to_string);
  check bool "failure reason null" true
    (match payload |> U.member "failure_reason" with
     | `Null -> true
     | _ -> false)

let test_stale_broadcast_payload_preserves_provider_failure_reason () =
  let failure_reason =
    Masc_mcp.Keeper_registry.Provider_runtime_error
      { code = "api_error_timeout"; detail = "Timeout after 300.0s" }
  in
  let payload =
    R.stale_broadcast_payload
      ~keeper_name:"executor"
      ~agent_name:"executor-agent"
      ~cascade_name:(R.cascade_name_of_string "tier_fast")
      ~trace_id:"trace-stale"
      ~generation:7
      ~failure_reason:(Some failure_reason)
      ~stale_seconds:630.0
      ~last_turn_ts:1777990000.0
  in
  check string "disposition reason" "provider_runtime_error"
    (payload |> U.member "disposition_reason" |> U.to_string);
  check string "terminal reason" "api_error_timeout"
    (payload |> U.member "terminal_reason_code" |> U.to_string);
  check string "failure cohort" "provider_runtime_error"
    (payload |> U.member "failure_reason_cohort" |> U.to_string);
  check string "failure reason detail"
    "provider_runtime_error(api_error_timeout:Timeout after 300.0s)"
    (payload |> U.member "failure_reason" |> U.to_string);
  check string "stale bucket" "stale_turn_10m_to_30m"
    (payload |> U.member "stale_turn_bucket" |> U.to_string)

let test_stale_broadcast_payload_preserves_required_tool_failure_reason () =
  let failure_reason =
    Masc_mcp.Keeper_registry.Tool_required_unsatisfied
      { code = "missing_required_tool_use"; detail = "keeper_shell missing" }
  in
  let payload =
    R.stale_broadcast_payload
      ~keeper_name:"executor"
      ~agent_name:"executor-agent"
      ~cascade_name:(R.cascade_name_of_string "tier_fast")
      ~trace_id:"trace-stale"
      ~generation:7
      ~failure_reason:(Some failure_reason)
      ~stale_seconds:75.0
      ~last_turn_ts:1777990000.0
  in
  check string "disposition reason" "tool_required_unsatisfied"
    (payload |> U.member "disposition_reason" |> U.to_string);
  check string "terminal reason" "missing_required_tool_use"
    (payload |> U.member "terminal_reason_code" |> U.to_string);
  check string "failure cohort" "tool_required_unsatisfied"
    (payload |> U.member "failure_reason_cohort" |> U.to_string);
  check string "failure reason detail"
    "tool_required_unsatisfied(missing_required_tool_use:keeper_shell missing)"
    (payload |> U.member "failure_reason" |> U.to_string);
  check string "stale bucket" "stale_turn_1m_to_5m"
    (payload |> U.member "stale_turn_bucket" |> U.to_string)

let test_stale_broadcast_payload_preserves_timeout_budget_failure_reason () =
  let failure_reason =
    Masc_mcp.Keeper_registry.Oas_timeout_budget_loop { count = 4 }
  in
  let payload =
    R.stale_broadcast_payload
      ~keeper_name:"executor"
      ~agent_name:"executor-agent"
      ~cascade_name:(R.cascade_name_of_string "tier_fast")
      ~trace_id:"trace-stale"
      ~generation:7
      ~failure_reason:(Some failure_reason)
      ~stale_seconds:1_900.0
      ~last_turn_ts:1777990000.0
  in
  check string "disposition reason" "oas_timeout_budget_loop"
    (payload |> U.member "disposition_reason" |> U.to_string);
  check string "terminal reason" "oas_timeout_budget"
    (payload |> U.member "terminal_reason_code" |> U.to_string);
  check string "failure cohort" "oas_timeout_budget_loop"
    (payload |> U.member "failure_reason_cohort" |> U.to_string);
  check string "failure reason detail" "oas_timeout_budget_loop(count=4)"
    (payload |> U.member "failure_reason" |> U.to_string);
  check string "stale bucket" "stale_turn_ge_30m"
    (payload |> U.member "stale_turn_bucket" |> U.to_string)

let () =
  run "keeper_pause_broadcast"
    [
      ( "operator_disposition",
        [
          test_case "all 8 contract violations -> pause_human" `Quick
            test_pause_human_for_each_violation;
          test_case "tools_used=[] -> pause_human" `Quick
            test_pause_human_when_no_tools_used;
          test_case
            "completion_contract_violation:* with satisfied_completion inner \
             -> pause_human (#11651 regression)"
            `Quick
            test_pause_human_for_completion_contract_violation_with_satisfied_inner;
          test_case
            "completion_contract_violation:other_subclause -> pause_human"
            `Quick
            test_pause_human_for_completion_contract_violation_other_subclause;
          test_case "provider failure before tool use -> provider_runtime_error" `Quick
            test_provider_failure_not_reported_as_tool_unsatisfied;
          test_case "config failure before tool use -> preflight_config_error" `Quick
            test_preflight_config_failure_not_reported_as_tool_unsatisfied;
          test_case "cascade_exhausted -> alert_exhausted" `Quick
            test_alert_for_cascade_exhausted;
          test_case "unmapped -> unknown" `Quick test_unknown_when_unmapped;
          test_case "ok+completed -> pass" `Quick test_pass_for_healthy;
          test_case "fallback -> pass_next_model" `Quick
            test_pass_next_for_cascade_fallback;
          test_case "degraded -> fail_open_next_cascade" `Quick
            test_fail_open_for_degraded_retry;
        ] );
      ( "needs_operator_broadcast",
        [
          test_case "exact predicate" `Quick test_needs_broadcast_predicate;
          test_case "all 3 broadcast paths reachable" `Quick
            test_each_broadcast_disp_is_reachable;
          test_case "broadcast payload carries turn diagnostics" `Quick
            test_broadcast_payload_carries_turn_diagnostics;
          test_case "stale payload uses low-cardinality reason" `Quick
            test_stale_broadcast_payload_uses_low_cardinality_stale_reason;
          test_case "stale payload preserves provider failure reason" `Quick
            test_stale_broadcast_payload_preserves_provider_failure_reason;
          test_case "stale payload preserves required-tool failure reason" `Quick
            test_stale_broadcast_payload_preserves_required_tool_failure_reason;
          test_case "stale payload preserves timeout-budget failure reason" `Quick
            test_stale_broadcast_payload_preserves_timeout_budget_failure_reason;
        ] );
    ]
