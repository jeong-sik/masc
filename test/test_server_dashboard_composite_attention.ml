open Alcotest
open Yojson.Safe.Util

let snapshot =
  `Assoc
    [ "is_live", `Bool false
    ; "fiber_stop_flag", `Bool false
    ; "turn_phase", `String "idle"
    ; "decision", `Assoc [ "stage", `String "undecided" ]
    ; "runtime", `Assoc [ "state", `String "idle" ]
    ; "compaction", `Assoc [ "stage", `String "accumulating" ]
    ]
;;

let execution completion_contract_result =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `String completion_contract_result
    ; "operator_disposition", `String "pass_next_model"
    ; "operator_disposition_reason", `Null
    ; "terminal_reason_code", `Null
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

(* The [terminal_reason_code] fixtures use the detail-less wire form
   ["turn_budget_exhausted(<used>/<limit>)"] because that is exactly what the
   receipt producer emits: [Runtime_agent.TurnBudgetExhausted] carries only
   {turns_used; limit}, so [Keeper_execution_receipt_types.stop_reason_to_string]
   serialises through [Keeper_turn_disposition.to_wire] with dimension/source
   = None. A prior change (#22618) replaced the original colon form with a
   fabricated full-detail "turn_budget_exhausted(turns:oas_sdk:1070/1070)" that
   no producer emits, decoupling this test from the producer. The producer↔wire
   round-trip is pinned in test_keeper_execution_receipt_budget_wire. *)
let completed_budget_execution =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `Null
    ; "operator_disposition", `String "pass"
    ; "operator_disposition_reason", `String "turn_budget_exhausted"
    ; "terminal_reason_code", `String "turn_budget_exhausted(1070/1070)"
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

let passive_budget_execution =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `String "passive_only"
    ; "operator_disposition", `String "pass"
    ; "operator_disposition_reason", `String "turn_budget_exhausted"
    ; "terminal_reason_code", `String "turn_budget_exhausted(1070/1070)"
    ; "current_task_id", `Null
    ; "goal_ids", `List []
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

let active_passive_budget_execution =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `String "passive_only"
    ; "operator_disposition", `String "pass"
    ; "operator_disposition_reason", `String "turn_budget_exhausted"
    ; "terminal_reason_code", `String "turn_budget_exhausted(1070/1070)"
    ; "current_task_id", `String "TASK-1"
    ; "goal_ids", `List []
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

let passive_execution_with_terminal_reason terminal_reason =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `String "passive_only"
    ; "operator_disposition", `String "pass"
    ; "operator_disposition_reason", `String "healthy"
    ; "terminal_reason_code", `String terminal_reason
    ; "current_task_id", `Null
    ; "goal_ids", `List []
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

let legacy_completed_passive_execution =
  passive_execution_with_terminal_reason "completed"
;;

let canonical_success_passive_execution =
  passive_execution_with_terminal_reason "success"
;;

let malformed_success_passive_execution =
  passive_execution_with_terminal_reason " SUCCESS "
;;

let trust_with_terminal_reason_code code =
  `Assoc
    [ ( "latest_terminal_reason"
      , `Assoc
          [ "code", `String code
          ; "severity", `Null
          ; "disposition", `Null
          ] )
    ]
;;

let active_success_passive_execution =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `String "passive_only"
    ; "operator_disposition", `String "pass"
    ; "operator_disposition_reason", `String "healthy"
    ; "terminal_reason_code", `String "success"
    ; "current_task_id", `String "TASK-1"
    ; "goal_ids", `List []
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

let not_dispatched_budget_execution =
  `Assoc
    [ "latest_receipt_present", `Bool true
    ; "recorded_at", `String "2999-01-01T00:00:00Z"
    ; "completion_contract_result", `String "not_dispatched"
    ; "operator_disposition", `String "pass"
    ; "operator_disposition_reason", `String "turn_budget_exhausted"
    ; "terminal_reason_code", `String "turn_budget_exhausted(1070/1070)"
    ; "error", `Null
    ; "claim_scope", `Assoc [ "status", `String "ok" ]
    ; "config_drift", `Assoc [ "runtime_override", `Bool false ]
    ]
;;

let test_contract_blocker_marks_attention () =
  let execution = execution "surface_mismatch" in
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention ~snapshot ~execution
  in
  check bool "blocked" true attention.cra_blocked;
  check bool "needs_attention" true attention.cra_needs_attention;
  check string "state" "blocked" attention.cra_state;
  check
    (option string)
    "reason"
    (Some "completion_contract_result:surface_mismatch")
    attention.cra_reason
;;

let test_drifted_contract_label_is_not_normalized () =
  let execution = execution " Surface_Mismatch " in
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention ~snapshot ~execution
  in
  check bool "blocked" false attention.cra_blocked;
  check bool "needs_attention" false attention.cra_needs_attention;
  check string "state" "ok" attention.cra_state;
  check (option string) "reason" None attention.cra_reason
;;

let test_contract_blocker_recommends_route_actions () =
  let execution = execution "no_capable_provider" in
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention ~snapshot ~execution
  in
  let actions =
    Server_dashboard_http_composite.composite_recommended_actions_json
      ~keeper_name:"keeper-a"
      ~snapshot
      ~execution
      ~attention
    |> to_list
  in
  check
    (list string)
    "action types"
    [ "keeper_message"; "keeper_probe" ]
    (actions
     |> List.map (fun action -> action |> member "action_type" |> to_string)
     |> List.sort String.compare);
  check
    bool
    "route reason"
    true
    (actions
     |> List.for_all (fun action ->
       let reason = action |> member "reason" |> to_string in
       String.starts_with ~prefix:"Inspect keeper tool-route contract blocker" reason
       || String.starts_with
            ~prefix:"Resolve keeper tool-route contract blocker before retry"
            reason))
;;

let test_completed_budget_exhaustion_is_not_blocked () =
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:completed_budget_execution
  in
  check bool "blocked" false attention.cra_blocked;
  check bool "needs_attention" false attention.cra_needs_attention;
  check string "state" "ok" attention.cra_state;
  check (option string) "reason" None attention.cra_reason
;;

let test_passive_budget_exhaustion_without_work_scope_is_not_blocked () =
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:passive_budget_execution
  in
  check bool "blocked" false attention.cra_blocked;
  check bool "needs_attention" false attention.cra_needs_attention;
  check string "state" "ok" attention.cra_state;
  check (option string) "reason" None attention.cra_reason
;;

let test_active_passive_budget_exhaustion_is_not_blocked () =
  (* RFC-0303 Phase 0: passive-only is activity, not a block — even with a
     claimed task (work scope) under turn-budget exhaustion. The budget
     disposition ("pass") is not an operator page, and passive no longer
     re-classifies as an unsatisfied contract. *)
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:active_passive_budget_execution
  in
  check bool "blocked" false attention.cra_blocked;
  check bool "needs_attention" false attention.cra_needs_attention;
  check string "state" "ok" attention.cra_state;
  check (option string) "reason" None attention.cra_reason
;;

let test_legacy_completed_receipt_is_blocked () =
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:legacy_completed_passive_execution
  in
  check bool "blocked" true attention.cra_blocked;
  check bool "needs_attention" true attention.cra_needs_attention;
  check string "state" "blocked" attention.cra_state
;;

let test_canonical_success_receipt_is_not_blocked () =
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:canonical_success_passive_execution
  in
  check bool "blocked" false attention.cra_blocked;
  check bool "needs_attention" false attention.cra_needs_attention;
  check string "state" "ok" attention.cra_state;
  check (option string) "reason" None attention.cra_reason
;;

let test_malformed_success_receipt_is_blocked () =
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:malformed_success_passive_execution
  in
  check bool "blocked" true attention.cra_blocked;
  check bool "needs_attention" true attention.cra_needs_attention;
  check string "state" "blocked" attention.cra_state
;;

let test_dashboard_execution_uses_strict_typed_success () =
  check bool "canonical success" false
    (Dashboard_execution.terminal_reason_requires_attention
       (trust_with_terminal_reason_code "success"));
  check bool "runtime completed is not final success" true
    (Dashboard_execution.terminal_reason_requires_attention
       (trust_with_terminal_reason_code "completed"));
  check bool "malformed success is not normalized" true
    (Dashboard_execution.terminal_reason_requires_attention
       (trust_with_terminal_reason_code " SUCCESS "))
;;

let test_active_success_passive_receipt_is_not_blocked () =
  (* RFC-0303 Phase 0: a successful passive-only turn with work scope is not a
     block. "Should it have acted on the claimed task?" is a goal-layer semantic
     judgment, not a per-turn dashboard attention flag. *)
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:active_success_passive_execution
  in
  check bool "blocked" false attention.cra_blocked;
  check bool "needs_attention" false attention.cra_needs_attention;
  check string "state" "ok" attention.cra_state;
  check (option string) "reason" None attention.cra_reason
;;

let test_not_dispatched_budget_exhaustion_is_blocked () =
  let attention =
    Server_dashboard_http_composite.composite_runtime_attention
      ~snapshot
      ~execution:not_dispatched_budget_execution
  in
  check bool "blocked" true attention.cra_blocked;
  check bool "needs_attention" true attention.cra_needs_attention;
  check string "state" "blocked" attention.cra_state;
  check
    (option string)
    "reason"
    (Some "completion_contract_result:not_dispatched")
    attention.cra_reason
;;

let () =
  run
    "server_dashboard_composite_attention"
    [ ( "tool-route contract blockers"
      , [ test_case "marks runtime attention" `Quick test_contract_blocker_marks_attention
        ; test_case "does not normalize drifted contract labels" `Quick
            test_drifted_contract_label_is_not_normalized
        ; test_case "emits route actions" `Quick
            test_contract_blocker_recommends_route_actions
        ] )
    ; ( "completed receipt semantics"
      , [ test_case
            "pass turn-budget exhaustion is not blocked"
            `Quick
            test_completed_budget_exhaustion_is_not_blocked
        ; test_case
            "passive turn-budget exhaustion without work scope is not blocked"
            `Quick
            test_passive_budget_exhaustion_without_work_scope_is_not_blocked
        ; test_case
            "active passive turn-budget exhaustion is not blocked"
            `Quick
            test_active_passive_budget_exhaustion_is_not_blocked
        ; test_case
            "legacy completed receipt is blocked"
            `Quick
            test_legacy_completed_receipt_is_blocked
        ; test_case
            "canonical success receipt is not blocked"
            `Quick
            test_canonical_success_receipt_is_not_blocked
        ; test_case
            "malformed success receipt is blocked"
            `Quick
            test_malformed_success_receipt_is_blocked
        ; test_case
            "dashboard execution uses strict typed success"
            `Quick
            test_dashboard_execution_uses_strict_typed_success
        ; test_case
            "active canonical success passive receipt is not blocked"
            `Quick
            test_active_success_passive_receipt_is_not_blocked
        ; test_case
            "not-dispatched turn-budget exhaustion is blocked"
            `Quick
            test_not_dispatched_budget_exhaustion_is_blocked
        ] )
    ]
;;
