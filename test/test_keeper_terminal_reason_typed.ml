(* RFC-0042 PR-4 behavioural equivalence + wire round-trip test.

   Two properties are pinned:

   1. [to_wire (of_wire s) = s] byte-for-byte for every representative
      producer code string (and a few adversarial ones). This proves the
      typed parse loses no information — every payload-bearing variant
      carries the original bytes.

   2. The NEW [Keeper_execution_receipt.operator_disposition] (which now
      parses [terminal_reason_code] once via [Keeper_terminal_reason.of_wire]
      and exhaustive-matches) returns the SAME (disposition, reason) pair as
      the frozen independent oracle over the cartesian product of
      (producer-string corpus) x (the small finite field matrix the
      classifier branches on). The oracle is intentionally NOT refactored to
      share code with production, so a priority-order regression in production
      is caught here. *)

module R = Masc.Keeper_execution_receipt
module C = Masc.Keeper_contract_classifier
module Tr = Keeper_terminal_reason
module UTS = Masc.Keeper_unified_turn_success.For_testing

let failures = ref []
let check name cond = if not cond then failures := name :: !failures

(* ------------------------------------------------------------------ *)
(* 1. Wire round-trip corpus: built from the PRODUCER sites, not from   *)
(*    the classifier prefixes. Includes the enriched contract-violation *)
(*    form, both api_error/provider_error families, the budget strings, *)
(*    direct producer strings, and one mixed-case adversarial input.    *)
(* ------------------------------------------------------------------ *)

let roundtrip_corpus =
  [ (* exact-match buckets *)
    "runtime_exhausted"
  ; "internal_error"
  ; "pre_dispatch_success"
  ; "provider_error"
    (* config/auth preflight (ranked above provider) *)
  ; "config_error"
  ; "api_error_auth"
  ; "provider_error_auth:openai"
  ; "provider_error_invalid_config:field_x"
    (* provider family *)
  ; "api_error_rate_limited"
  ; "api_error_overloaded"
  ; "api_error_server:502"
  ; "api_error_timeout"
  ; "api_error_network"
  ; "api_error_context_overflow"
  ; "api_error_oas_agent_execution_timeout"
  ; "provider_error_parse"
  ; "provider_error_server:500"
  ; "provider_error_missing_api_key"
  ; "provider_error_hard_quota:openai"
    (* completion-contract-violation (legacy + enriched forms) *)
  ; "completion_contract_violation:completion_contract"
  ; "completion_contract_violation:completion_contract:called[a,b]:satisfying[c]"
    (* turn-livelock *)
  ; "turn_livelock:stuck_age_exceeded"
    (* budget cut-offs *)
  ; "agent_error_max_turns_exceeded:turns=8,limit=8"
  ; "agent_error_execution_timeout:elapsed_sec=120.0,timeout_sec=120.0,turn_count=7,max_turns=8"
  ; "agent_error_idle_timeout:idle_sec=120.0,idle_timeout_sec=120.0,turn_count=7,max_turns=8"
  ; "turn_budget_exhausted:8/8"
    (* genuine Other (preserve-don't-fix) *)
  ; "no_capable_provider"
  ; "mcp_error"
  ; "serialization_error"
  ; "io_error"
  ; "orchestration_error"
  ; "a2a_error"
  ; "agent_error_token_budget_exceeded:kind=output,used=100,limit=50"
  ; "agent_error_guardrail_violation:validator=x"
  ; "agent_error_idle_detected:consecutive_idle_turns=3"
  ; "registry_phase_missing"
  ; "supervisor_stop"
    (* adversarial: mixed case must round-trip to the original bytes *)
  ; "Runtime_Exhausted"
  ; "API_ERROR_Auth"
  ; ""
  ]

let () =
  List.iter
    (fun s ->
       let got = Tr.to_wire (Tr.of_wire s) in
       check
         (Printf.sprintf "roundtrip: %S -> %S" s got)
         (String.equal got s))
    roundtrip_corpus
;;

(* ------------------------------------------------------------------ *)
(* 1b. is_completion_contract_violation: OAS no longer emits completion
   contract SDK errors, so structured SDK errors all return false. #19930 *)
(* ------------------------------------------------------------------ *)

module EC = Masc.Keeper_error_classify

let () =
  check "non-contract: provider timeout"
    (not (EC.is_completion_contract_violation
            (Agent_sdk.Error.Api
               (Llm_provider.Retry.Timeout
                  { message = "timeout"; phase = None }))));
  check "non-contract: rate limited"
    (not (EC.is_completion_contract_violation
            (Agent_sdk.Error.Api
               (Llm_provider.Retry.RateLimited
                  { message = "rate limited"; retry_after = None }))));
  check "non-contract: server error"
    (not (EC.is_completion_contract_violation
            (Agent_sdk.Error.Api
               (Llm_provider.Retry.ServerError
                  { message = "server error"; status = 500 }))));
  check "non-contract: overloaded"
    (not (EC.is_completion_contract_violation
            (Agent_sdk.Error.Api
               (Llm_provider.Retry.Overloaded
                  { message = "overloaded" }))));
  check "non-contract: MaxTurnsExceeded"
    (not (EC.is_completion_contract_violation
            (Agent_sdk.Error.Agent
               (Agent_sdk.Error.MaxTurnsExceeded
                  { turns = 8; limit = 8 }))));
  check "non-contract: Internal"
    (not (EC.is_completion_contract_violation
            (Agent_sdk.Error.Internal "internal error")));
;;

(* ------------------------------------------------------------------ *)
(* 2. (disposition, reason) equivalence vs a frozen copy of the OLD    *)
(*    substring classifier.                                            *)
(* ------------------------------------------------------------------ *)

(* Frozen copy of the pre-typing [operator_disposition] body plus explicit
   policy updates pinned by focused regressions below. DO NOT refactor to call
   production helpers — this is the oracle. *)
let string_contains_ci = String_util.contains_substring_ci

let frozen_terminal_prefix_max_turns_exceeded = "agent_error_max_turns_exceeded"
let frozen_terminal_prefix_execution_timeout = "agent_error_execution_timeout"
let frozen_terminal_prefix_idle_timeout = "agent_error_idle_timeout"
let frozen_terminal_prefix_turn_budget_exhausted = "turn_budget_exhausted"

let frozen_is_auto_recoverable_turn_budget_terminal terminal_reason =
  String.starts_with ~prefix:frozen_terminal_prefix_max_turns_exceeded terminal_reason
  || String.starts_with ~prefix:frozen_terminal_prefix_execution_timeout terminal_reason
  || String.starts_with ~prefix:frozen_terminal_prefix_idle_timeout terminal_reason
;;

let frozen_is_turn_budget_exhausted_terminal terminal_reason =
  String.starts_with ~prefix:frozen_terminal_prefix_turn_budget_exhausted terminal_reason
;;

let frozen_completion_contract_satisfied = function
  | R.Contract_satisfied_completion | R.Contract_satisfied_execution -> true
  | R.Contract_unknown
  | R.Contract_not_dispatched
  | R.Contract_violated
  | R.Contract_surface_mismatch
  | R.Contract_no_capable_provider
  | R.Contract_claim_only_after_owned_task
  | R.Contract_needs_execution_progress
  | R.Contract_passive_only -> false
;;

let frozen_completion_contract_unsatisfied = function
  | R.Contract_violated
  | R.Contract_claim_only_after_owned_task
  | R.Contract_needs_execution_progress
  | R.Contract_passive_only -> true
  | R.Contract_unknown
  | R.Contract_not_dispatched
  | R.Contract_surface_mismatch
  | R.Contract_no_capable_provider
  | R.Contract_satisfied_completion
  | R.Contract_satisfied_execution -> false
;;

let frozen_is_transient_provider_runtime_failure terminal_reason =
  String.equal terminal_reason "api_error_timeout"
  || String.equal terminal_reason "api_error_network"
;;

let frozen_operator_disposition (receipt : R.t)
  : R.operator_disposition_kind * R.operator_disposition_reason
  =
  let terminal_reason = String.lowercase_ascii receipt.terminal_reason_code in
  let error_kind =
    Option.map
      (fun kind -> String.lowercase_ascii (R.error_kind_to_string kind))
      receipt.error_kind
  in
  let provider_runtime_failure =
    String.starts_with ~prefix:"api_error_" terminal_reason
    || String.equal terminal_reason "provider_error"
    || String.starts_with ~prefix:"provider_error_" terminal_reason
    ||
    match error_kind with
    | Some ("api" | "mcp" | "io" | "orchestration" | "serialization") -> true
    | Some _ | None -> false
  in
  let preflight_config_failure =
    match error_kind with
    | Some kind ->
      string_contains_ci kind "config"
      || string_contains_ci kind "auth"
      || string_contains_ci terminal_reason "config"
      || string_contains_ci terminal_reason "auth"
    | None ->
      string_contains_ci terminal_reason "config"
      || string_contains_ci terminal_reason "auth"
  in
  if String.equal terminal_reason "runtime_exhausted"
  then R.Disp_alert_exhausted, R.Reason_runtime_exhausted
  else if preflight_config_failure
  then R.Disp_pause_human, R.Reason_preflight_config_error
  else if
    provider_runtime_failure
    && (receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime)
  then R.Disp_fail_open_next_runtime, R.Reason_degraded_retry
  else if
    provider_runtime_failure
    && (receipt.runtime_fallback_applied
        || receipt.runtime_outcome = R.Runtime_passed_to_next_model)
  then R.Disp_pass_next_model, R.Reason_runtime_fallback
  else if
    provider_runtime_failure
    && frozen_is_transient_provider_runtime_failure terminal_reason
  then R.Disp_fail_open_next_runtime, R.Reason_transient_runtime_retry
  else if provider_runtime_failure
  then R.Disp_pause_human, R.Reason_provider_runtime_error
  else if String.starts_with ~prefix:"completion_contract_violation:" terminal_reason
  then R.Disp_pause_human, R.Reason_unmapped_runtime_state
  else if
    String.starts_with ~prefix:"turn_livelock:" terminal_reason
    ||
    match error_kind with
    | Some "turn_livelock_blocked" -> true
    | Some _ | None -> false
  then R.Disp_pause_human, R.Reason_turn_livelock_blocked
  else if
    String.equal terminal_reason "internal_error"
    ||
    match error_kind with
    | Some "internal" -> true
    | Some _ | None -> false
  then R.Disp_pause_human, R.Reason_internal_error
  else if frozen_is_auto_recoverable_turn_budget_terminal terminal_reason
  then R.Disp_pass, R.Reason_turn_budget_exhausted
  else (
    let tool_route_failure =
      List.mem
        receipt.completion_contract_result
        [ R.Contract_surface_mismatch; R.Contract_no_capable_provider ]
    in
    if tool_route_failure
    then
      if receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime
      then R.Disp_fail_open_next_runtime, R.Reason_tool_route_recoverable_failure
      else if
        receipt.runtime_fallback_applied
        || receipt.runtime_outcome = R.Runtime_passed_to_next_model
      then R.Disp_pass_next_model, R.Reason_tool_route_recoverable_failure
      else R.Disp_pause_human, R.Reason_tool_route_recoverable_failure
    else if
      receipt.degraded_retry_applied || Option.is_some receipt.degraded_retry_runtime
    then R.Disp_fail_open_next_runtime, R.Reason_degraded_retry
    else if
      receipt.runtime_fallback_applied
      || receipt.runtime_outcome = R.Runtime_passed_to_next_model
    then R.Disp_pass_next_model, R.Reason_runtime_fallback
    else if frozen_is_turn_budget_exhausted_terminal terminal_reason
    then
      if frozen_completion_contract_satisfied receipt.completion_contract_result
      then R.Disp_pass, R.Reason_turn_budget_exhausted
      else R.Disp_alert_exhausted, R.Reason_turn_budget_exhausted
    else if frozen_completion_contract_unsatisfied receipt.completion_contract_result
    then R.Disp_pause_human, R.Reason_completion_contract_unsatisfied
    else if
      receipt.outcome = `Ok
      && receipt.runtime_outcome = R.Runtime_not_dispatched
      && receipt.completion_contract_result = R.Contract_not_dispatched
      && String.equal terminal_reason "pre_dispatch_success"
    then R.Disp_pass, R.Reason_healthy
    else (
      match receipt.outcome with
      | `Cancelled -> R.Disp_user_cancelled, R.Reason_cancelled
      | `Skipped -> R.Disp_skipped, R.Reason_phase_skipped
      | `Ok when receipt.runtime_outcome = R.Runtime_completed ->
        R.Disp_pass, R.Reason_healthy
      | `Ok when receipt.runtime_outcome = R.Runtime_not_dispatched ->
        R.Disp_pass, R.Reason_healthy
      | _ -> R.Disp_unknown, R.Reason_unmapped_runtime_state))
;;

(* ------------------------------------------------------------------ *)
(* Base receipt + field-matrix axes.                                   *)
(* ------------------------------------------------------------------ *)

let base_tool_surface : R.tool_surface =
  { turn_lane = Masc.Keeper_agent_tool_surface.Lane_tool_optional }
;;

let base_receipt : R.t =
  { keeper_name = "test-keeper"
  ; agent_name = "test-agent"
  ; trace_id = "trace-1"
  ; generation = 1
  ; turn_count = Some 1
  ; oas_turn_count = None
  ; oas_dispatch_mode = None
  ; oas_internal_runtime_disabled = false
  ; current_task_id = None
  ; goal_ids = []
  ; outcome = `Error
  ; terminal_reason_code = ""
  ; response_text_present = false
  ; model_used = None
  ; completion_contract_result = R.Contract_unknown
  ; actionable_signal = Some C.No_actionable_signal
    (* Root B (#22710): the base receipt represents an idle keeper with nothing
       actionable, the same "no-work" baseline the prior [goal_ids = []] default
       expressed. The passive-only carve-out now reads this signal. *)
  ; tool_surface = base_tool_surface
  ; sandbox_kind = Keeper_types_profile_sandbox.Local
  ; sandbox_root = None
  ; network_mode = Keeper_types_profile_sandbox.Network_none
  ; runtime_id = "runtime-1"
  ; runtime_selected_model = None
  ; runtime_attempt_count = 1
  ; runtime_fallback_applied = false
  ; runtime_outcome = R.Runtime_completed
  ; oas_internal_runtime_allowed = true
  ; degraded_retry_applied = false
  ; degraded_retry_runtime = None
  ; fallback_reason = None
  ; runtime_rotation_attempts = []
  ; stop_reason = None
  ; error_kind = None
  ; error_message = None
  ; started_at = "2026-06-03T00:00:00Z"
  ; ended_at = "2026-06-03T00:00:01Z"
  ; extra_system_context_digest = None
  ; extra_system_context_injected_size = None
  ; extra_system_context_computed_size = None
  ; pre_dispatch_compacted = false
  ; pre_dispatch_compaction_trigger = None
  ; pre_dispatch_compaction_before_tokens = None
  ; pre_dispatch_compaction_after_tokens = None
  }
;;

(* Field matrix axes. Kept small but covering the dimensions the
   classifier branches on. *)
let codes = roundtrip_corpus

let error_kinds =
  [ None
  ; Some (R.error_kind_of_string "config")
  ; Some (R.error_kind_of_string "auth")
  ; Some (R.error_kind_of_string "api")
  ; Some (R.error_kind_of_string "mcp")
  ; Some (R.error_kind_of_string "internal")
  ; Some (R.error_kind_of_string "turn_livelock_blocked")
  ; Some (R.error_kind_of_string "provider")
  ; Some (R.error_kind_of_string "io")
  ]

let degraded_bools = [ false; true ]
let fallback_bools = [ false; true ]

let runtime_outcomes =
  [ R.Runtime_completed
  ; R.Runtime_failed
  ; R.Runtime_passed_to_next_model
  ; R.Runtime_not_observed
  ; R.Runtime_not_dispatched
  ]

let completion_contract_results =
  [ R.Contract_unknown
  ; R.Contract_not_dispatched
  ; R.Contract_no_capable_provider
  ; R.Contract_surface_mismatch
  ; R.Contract_needs_execution_progress
  ; R.Contract_passive_only
  ; R.Contract_satisfied_completion
  ; R.Contract_satisfied_execution
  ]

let outcomes = [ `Ok; `Error; `Cancelled; `Skipped ]

let disp_pair_to_string (d, r) =
  Printf.sprintf
    "(%s, %s)"
    (R.operator_disposition_kind_to_string d)
    (R.operator_disposition_reason_to_string r)
;;

let operator_disposition_kinds =
  [ R.Disp_pass
  ; R.Disp_pause_human
  ; R.Disp_alert_exhausted
  ; R.Disp_fail_open_next_runtime
  ; R.Disp_pass_next_model
  ; R.Disp_user_cancelled
  ; R.Disp_skipped
  ; R.Disp_unknown
  ]
;;

let () =
  List.iter
    (fun disposition ->
       let label = R.operator_disposition_kind_to_string disposition in
       let parsed =
         R.operator_disposition_kind_of_string label
         |> Option.map R.operator_disposition_kind_to_string
       in
       check
         (Printf.sprintf
            "operator_disposition_kind_of_string round-trips %s"
            label)
         (parsed = Some label))
    operator_disposition_kinds;
  check
    "operator_disposition_kind_of_string rejects legacy blocked_runtime"
    (R.operator_disposition_kind_of_string "blocked_runtime" = None)
;;

let intentional_passive_only_policy_change (receipt : R.t) got =
  if receipt.completion_contract_result <> R.Contract_passive_only
  then false
  else
    match got with
    (* RFC-0303 Phase 0: passive-only is activity, not a page. Wherever the
       frozen oracle routed a passive turn to the contract-unsatisfied pause
       ([Disp_pause_human]/[completion_contract_unsatisfied]), the live function
       now returns a non-paging [Disp_pass]/[passive_no_action] — regardless of
       work scope. This is the intended reversal of the albini "85 pages/day"
       classification. *)
    | R.Disp_pass, R.Reason_passive_no_action -> true
    (* Pre-existing no-work carve-outs (frozen oracle predates them): a passive
       turn with no claimed task and no actionable signal already passed. *)
    | R.Disp_pass, R.Reason_turn_budget_exhausted
      when Option.is_none receipt.current_task_id
           && receipt.actionable_signal = Some C.No_actionable_signal
           && receipt.outcome = `Ok
           && String.starts_with
                ~prefix:"turn_budget_exhausted"
                (String.lowercase_ascii receipt.terminal_reason_code) ->
      true
    | R.Disp_pass, R.Reason_healthy
      when Option.is_none receipt.current_task_id
           && receipt.actionable_signal = Some C.No_actionable_signal
           && receipt.outcome = `Ok
           && receipt.runtime_outcome = R.Runtime_completed
           && (let c = String.lowercase_ascii receipt.terminal_reason_code in
               c = "completed" || c = "success") ->
      true
    | _ -> false
;;

(* To keep the product bounded we vary the most behaviour-determining axes
   fully and pin the others to representative values per code, plus a
   focused sub-matrix over the provider/route axes. *)
let () =
  let count = ref 0 in
  let mismatches = ref 0 in
  List.iter
    (fun code ->
       List.iter
         (fun error_kind ->
            List.iter
              (fun degraded ->
                 List.iter
                   (fun fallback ->
                      List.iter
                        (fun runtime_outcome ->
                           List.iter
                             (fun tcr ->
                                List.iter
                                  (fun outcome ->
                                     let receipt =
                                       { base_receipt with
                                         terminal_reason_code = code
                                       ; error_kind
                                       ; degraded_retry_applied = degraded
                                       ; runtime_fallback_applied = fallback
                                       ; runtime_outcome
                                       ; completion_contract_result = tcr
                                       ; outcome
                                       }
                                     in
                                     incr count;
                                     let want =
                                       frozen_operator_disposition receipt
                                     in
                                     let got =
                                       R.operator_disposition receipt
                                     in
                                     if want <> got
                                        && not
                                             (intentional_passive_only_policy_change
                                                receipt
                                                got)
                                     then (
                                       incr mismatches;
                                       if !mismatches <= 20
                                       then
                                         check
                                           (Printf.sprintf
                                              "disp-mismatch code=%S ek=%s out=%s ro=%s tcr=%s deg=%b fb=%b want=%s got=%s"
                                              code
                                              (match error_kind with
                                               | None -> "none"
                                               | Some k -> R.error_kind_to_string k)
                                              (R.outcome_kind_to_string outcome)
                                              (R.runtime_outcome_to_string
                                                 runtime_outcome)
                                              (R.completion_contract_result_to_string tcr)
                                              degraded
                                              fallback
                                              (disp_pair_to_string want)
                                              (disp_pair_to_string got))
                                           false))
                                  outcomes)
                             completion_contract_results)
                        runtime_outcomes)
                   fallback_bools)
              degraded_bools)
         error_kinds)
    codes;
  Printf.printf
    "test_keeper_terminal_reason_typed: matrix cases=%d mismatches=%d\n"
    !count
    !mismatches
;;

let () =
  let code = "provider_error_timeout:http_operation" in
  check
    "provider timeout marker is transient"
    (Tr.is_transient_provider_runtime_failure (Tr.of_wire code));
  let receipt =
    { base_receipt with
      terminal_reason_code = code
    ; error_kind = Some (R.error_kind_of_string "provider")
    ; outcome = `Error
    ; runtime_outcome = R.Runtime_failed
    }
  in
  let got = R.operator_disposition receipt in
  let want = R.Disp_fail_open_next_runtime, R.Reason_transient_runtime_retry in
  check
    (Printf.sprintf
       "provider timeout marker disposition want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want)
;;

let () =
  let code = "provider_error_parse" in
  check
    "provider parse marker is provider runtime failure"
    (match Tr.of_wire code with
     | Tr.Provider_runtime_failure wire -> String.equal wire code
     | _ -> false);
  check
    "provider parse marker is not transient"
    (not (Tr.is_transient_provider_runtime_failure (Tr.of_wire code)));
  let receipt =
    { base_receipt with
      terminal_reason_code = code
    ; error_kind = Some (R.error_kind_of_string "provider")
    ; outcome = `Error
    ; runtime_outcome = R.Runtime_failed
    }
  in
  let got = R.operator_disposition receipt in
  let want = R.Disp_pause_human, R.Reason_provider_runtime_error in
  check
    (Printf.sprintf
       "provider parse marker disposition want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want)
;;

let () =
  let code = "turn_budget_exhausted:12704/12704" in
  let passive_receipt =
    { base_receipt with
      terminal_reason_code = code
    ; outcome = `Ok
    ; runtime_outcome = R.Runtime_completed
    ; completion_contract_result = R.Contract_passive_only
    }
  in
  let got = R.operator_disposition passive_receipt in
  (* RFC-0303 Phase 0: passive-only is not an operator page even when the
     turn also exhausted its budget (review-flagged gap on this PR: the
     turn_budget_exhausted branch used to return before ever reaching the
     Contract_passive_only carve-out, so its Disp_pass carried the
     misleading [Reason_turn_budget_exhausted] instead of
     [Reason_passive_no_action]). *)
  let want = R.Disp_pass, R.Reason_passive_no_action in
  check
    (Printf.sprintf
       "no-work passive turn budget exhaustion want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  let active_passive_receipt =
    { passive_receipt with current_task_id = Some "TASK-1" }
  in
  let got = R.operator_disposition active_passive_receipt in
  (* Same carve-out extends to passive-WITH-work-scope turns (current_task_id
     set): before this fix this case fell through to
     [Disp_alert_exhausted, Reason_turn_budget_exhausted], paging an operator
     for activity RFC-0303 says should never page. *)
  let want = R.Disp_pass, R.Reason_passive_no_action in
  check
    (Printf.sprintf
       "active passive turn budget exhaustion want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  let executed_receipt =
    { passive_receipt with
      completion_contract_result = R.Contract_satisfied_execution
    }
  in
  let got = R.operator_disposition executed_receipt in
  let want = R.Disp_pass, R.Reason_turn_budget_exhausted in
  check
    (Printf.sprintf
       "satisfied turn budget exhaustion want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want)
;;

let () =
  let receipt =
    { base_receipt with
      terminal_reason_code = "completed"
    ; outcome = `Ok
    ; runtime_outcome = R.Runtime_completed
    ; completion_contract_result = R.Contract_passive_only
    }
  in
  let got = R.operator_disposition receipt in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "completed no-work passive-only receipt want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  (* RFC-0303 Phase 0: a passive-only turn is activity, not a page — even when
     the keeper holds a claimed task. It maps to [Disp_pass]/[passive_no_action],
     NOT [Disp_pause_human]. "Should it have worked the claimed task?" is a
     goal-layer judgment, not a per-turn contract failure. *)
  let active_receipt = { receipt with current_task_id = Some "TASK-1" } in
  let got = R.operator_disposition active_receipt in
  let want = R.Disp_pass, R.Reason_passive_no_action in
  check
    (Printf.sprintf
       "completed active passive-only receipt is pass (not a page) want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "active passive-only turn does NOT need an operator broadcast"
    (not (R.needs_operator_broadcast (fst got)))
;;

(* Root B (#22710) regression: a coordination keeper always carries goals
   (goal_ids <> []), yet may have nothing actionable in a given turn. The
   passive-only carve-out must key on the world-observation [actionable_signal],
   not on goal presence; otherwise such a keeper fails the healthy carve-out and
   re-emits [operator_broadcast_required] every idle turn (albini, 85/day). *)
let () =
  let coordination_passive ?(actionable_signal = Some C.No_actionable_signal) () =
    { base_receipt with
      terminal_reason_code = "completed"
    ; outcome = `Ok
    ; runtime_outcome = R.Runtime_completed
    ; completion_contract_result = R.Contract_passive_only
    ; goal_ids = [ "GOAL-1" ]
    ; actionable_signal
    }
  in
  let got = R.operator_disposition (coordination_passive ()) in
  let want = R.Disp_pass, R.Reason_healthy in
  check
    (Printf.sprintf
       "coordination keeper with goals + no actionable signal is healthy want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "healthy idle coordination turn does not need an operator broadcast"
    (not (R.needs_operator_broadcast (fst got)));
  let got =
    R.operator_disposition
      (coordination_passive ~actionable_signal:(Some C.Has_unclaimed_tasks) ())
  in
  (* RFC-0303 Phase 0: the albini "85 pages/day" root. A coordination keeper
     that saw unclaimed tasks but chose not to claim one this turn is NOT a
     page — choosing not to act on available work is a decision, not a contract
     failure. Passive-only is uniformly [Disp_pass]/[passive_no_action]. *)
  let want = R.Disp_pass, R.Reason_passive_no_action in
  check
    (Printf.sprintf
       "coordination keeper with unclaimed tasks does NOT page (passive is a \
        decision, not a failure) want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want);
  check
    "unclaimed-task passive turn does NOT need an operator broadcast"
    (not (R.needs_operator_broadcast (fst got)));
  (* RFC-0303 Phase 0: with no world observation threaded, a passive-only turn
     is still not a page. Observability loss is a runtime concern (surfaced on
     the runtime error path), not a manufactured passive-turn operator page. *)
  let got = R.operator_disposition (coordination_passive ~actionable_signal:None ()) in
  let want = R.Disp_pass, R.Reason_passive_no_action in
  check
    (Printf.sprintf
       "coordination keeper with no observation is pass (passive is not a page) \
        want=%s got=%s"
       (disp_pair_to_string want)
       (disp_pair_to_string got))
    (got = want)
;;

let () =
  let completion_contract_failure =
    UTS.Terminal_failed_completion_contract
      { reason_code = "needs_execution_progress" }
  in
  check
    "completion-contract terminal failure is not a completed activity turn"
    (not (UTS.terminal_outcome_is_completed_turn completion_contract_failure));
  check
    "completion-contract terminal failure persists keeper turn usage"
    (UTS.terminal_outcome_persists_turn_usage completion_contract_failure)
;;

let () =
  match !failures with
  | [] -> print_endline "test_keeper_terminal_reason_typed: OK"
  | xs ->
    List.iter (fun n -> print_endline ("FAIL: " ^ n)) (List.rev xs);
    failwith
      (Printf.sprintf "%d terminal-reason-typed assertion(s) failed" (List.length xs))
;;
