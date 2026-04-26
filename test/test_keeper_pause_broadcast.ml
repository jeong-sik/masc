(* Tests for keeper_execution_receipt operator_disposition / broadcast hook
   (#fleet-stall 2026-04-26).

   Verifies that the silent-dead-end fix in
   [Keeper_execution_receipt.append] classifies pause/exhausted/unknown
   states as broadcast-worthy, while healthy/forward-progress states do
   not trigger an operator broadcast. The end-to-end Activity_graph emit
   path is exercised by the integration smoke (Step 5 part 2). *)

open Alcotest
module R = Masc_mcp.Keeper_execution_receipt

let mk_tool_surface ?(tool_requirement = "required") ?(missing_required_tools = []) ()
  : R.tool_surface
  =
  { turn_lane = "unified"
  ; tool_surface_class = "post_dispatch"
  ; tool_requirement
  ; visible_tool_count = 1
  ; tool_gate_enabled = true
  ; tool_surface_fallback_used = false
  ; required_tools = []
  ; missing_required_tools
  }
;;

let mk_receipt
      ?(outcome = "error")
      ?(terminal_reason_code = "")
      ?(tool_contract_result = "satisfied")
      ?(tools_used = [ "Read" ])
      ?(tool_requirement = "required")
      ?(cascade_outcome = "completed")
      ?(error_kind = None)
      ?(error_message = None)
      ?(degraded_retry_applied = false)
      ?(cascade_fallback_applied = false)
      ()
  : R.t
  =
  { keeper_name = "test-keeper"
  ; agent_name = "test-agent"
  ; trace_id = "trace-test"
  ; generation = 1
  ; turn_count = Some 1
  ; current_task_id = None
  ; goal_ids = []
  ; outcome
  ; terminal_reason_code
  ; response_text_present = true
  ; model_used = None
  ; requested_tools = []
  ; reported_tools = []
  ; observed_tools = []
  ; canonical_tools = []
  ; unexpected_tools = []
  ; tools_used
  ; tool_contract_result
  ; tool_surface = mk_tool_surface ~tool_requirement ()
  ; sandbox_kind = "local"
  ; sandbox_root = None
  ; network_mode = "offline"
  ; approval_profile = None
  ; approval_profile_derived = false
  ; cascade_name = "default"
  ; cascade_selected_model = None
  ; cascade_attempt_count = 1
  ; cascade_fallback_applied
  ; cascade_outcome
  ; degraded_retry_applied
  ; degraded_retry_cascade = None
  ; fallback_reason = None
  ; cascade_rotation_attempts = []
  ; stop_reason = None
  ; error_kind
  ; error_message
  ; started_at = "2026-04-26T00:00:00Z"
  ; ended_at = "2026-04-26T00:00:01Z"
  }
;;

let check_disp label receipt expected_disp expected_reason =
  let disp, reason = R.operator_disposition receipt in
  check string (label ^ " (disposition)") expected_disp disp;
  check string (label ^ " (reason)") expected_reason reason
;;

(* === Bug class: tool_contract_result violations must pause_human ====== *)

let violation_variants =
  [ "violated"
  ; "unknown"
  ; "needs_execution_progress"
  ; "missing_required_tool_use"
  ; "passive_only"
  ; "claim_only_after_owned_task"
  ; "tool_surface_mismatch"
  ; "no_tool_capable_provider"
  ]
;;

let test_pause_human_for_each_violation () =
  List.iter
    (fun v ->
       let r = mk_receipt ~tool_contract_result:v () in
       check_disp ("violation:" ^ v) r "pause_human" "tool_required_unsatisfied")
    violation_variants
;;

let test_pause_human_when_no_tools_used () =
  let r = mk_receipt ~tools_used:[] () in
  check_disp "tools_used=[]" r "pause_human" "tool_required_unsatisfied"
;;

(* === Cascade exhausted always alerts ================================ *)

let test_alert_for_cascade_exhausted () =
  let r =
    mk_receipt ~terminal_reason_code:"cascade_exhausted" ~cascade_outcome:"exhausted" ()
  in
  check_disp "cascade_exhausted" r "alert_exhausted" "cascade_exhausted"
;;

(* === Unknown / unmapped state must NOT silently look healthy ========= *)

let test_unknown_when_unmapped () =
  let r =
    mk_receipt
      ~outcome:"weird"
      ~cascade_outcome:"weird"
      ~tool_contract_result:"satisfied"
      ()
  in
  check_disp "unmapped" r "unknown" "unmapped_cascade_state"
;;

(* === Forward-progress states do NOT broadcast ======================== *)

let test_pass_for_healthy () =
  let r =
    mk_receipt
      ~outcome:"ok"
      ~cascade_outcome:"completed"
      ~tool_contract_result:"satisfied"
      ~terminal_reason_code:"completed"
      ()
  in
  check_disp "healthy" r "pass" "healthy"
;;

let test_pass_next_for_cascade_fallback () =
  let r =
    mk_receipt
      ~cascade_fallback_applied:true
      ~cascade_outcome:"passed_to_next_model"
      ~tool_contract_result:"satisfied"
      ()
  in
  check_disp "cascade_fallback" r "pass_next_model" "cascade_fallback"
;;

let test_fail_open_for_degraded_retry () =
  let r = mk_receipt ~degraded_retry_applied:true ~tool_contract_result:"satisfied" () in
  check_disp "degraded_retry" r "fail_open_next_cascade" "degraded_retry"
;;

(* === Trigger predicate ============================================== *)

let test_needs_broadcast_predicate () =
  check bool "pause_human triggers" true (R.needs_operator_broadcast "pause_human");
  check
    bool
    "alert_exhausted triggers"
    true
    (R.needs_operator_broadcast "alert_exhausted");
  check bool "unknown triggers" true (R.needs_operator_broadcast "unknown");
  check bool "pass does not" false (R.needs_operator_broadcast "pass");
  check
    bool
    "pass_next_model does not"
    false
    (R.needs_operator_broadcast "pass_next_model");
  check
    bool
    "fail_open_next_cascade does not"
    false
    (R.needs_operator_broadcast "fail_open_next_cascade")
;;

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
    mk_receipt
      ~outcome:"weird"
      ~cascade_outcome:"weird"
      ~tool_contract_result:"satisfied"
      ()
  in
  let d3, _ = R.operator_disposition r3 in
  check bool "unknown reachable" true (R.needs_operator_broadcast d3)
;;

let () =
  run
    "keeper_pause_broadcast"
    [ ( "operator_disposition"
      , [ test_case
            "all 8 contract violations -> pause_human"
            `Quick
            test_pause_human_for_each_violation
        ; test_case
            "tools_used=[] -> pause_human"
            `Quick
            test_pause_human_when_no_tools_used
        ; test_case
            "cascade_exhausted -> alert_exhausted"
            `Quick
            test_alert_for_cascade_exhausted
        ; test_case "unmapped -> unknown" `Quick test_unknown_when_unmapped
        ; test_case "ok+completed -> pass" `Quick test_pass_for_healthy
        ; test_case
            "fallback -> pass_next_model"
            `Quick
            test_pass_next_for_cascade_fallback
        ; test_case
            "degraded -> fail_open_next_cascade"
            `Quick
            test_fail_open_for_degraded_retry
        ] )
    ; ( "needs_operator_broadcast"
      , [ test_case "exact predicate" `Quick test_needs_broadcast_predicate
        ; test_case
            "all 3 broadcast paths reachable"
            `Quick
            test_each_broadcast_disp_is_reachable
        ] )
    ]
;;
