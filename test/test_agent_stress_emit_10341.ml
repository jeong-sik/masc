(** Agent_stress emit-site coverage for non-keepalive failure modes.

    Regression for masc-mcp #10341: the [Agent_stress] module defines
    five stress dimensions (Failure_streak, Fallback_approval, Timeout,
    Parse_degraded, Task_released) but only [Failure_streak] was being
    written by [keeper_keepalive].  Result: 24h+ stale ledger with 1
    entry while institution episodes recorded 76 turn failures.

    This test pins the [stress_kind_of_error_kind] classifier so future
    error_kind additions get explicit decisions. *)

open Alcotest
open Masc_mcp

let kind_eq a b =
  match (a, b) with
  | Agent_stress.Timeout, Agent_stress.Timeout -> true
  | Agent_stress.Parse_degraded, Agent_stress.Parse_degraded -> true
  | Agent_stress.Failure_streak n, Agent_stress.Failure_streak m -> n = m
  | Agent_stress.Fallback_approval, Agent_stress.Fallback_approval -> true
  | Agent_stress.Task_released, Agent_stress.Task_released -> true
  | Agent_stress.Turn_failure _, Agent_stress.Turn_failure _ ->
      (* Turn_failure carries diagnostic record fields (consecutive,
         threshold, ...) added by #10362.  This test suite only
         exercises the [stress_kind_of_error_kind] classifier from
         #10341 which never returns Turn_failure, so structural
         equality on the variant tag is sufficient. *)
      true
  | _ -> false

let opt_kind = testable
    (fun fmt -> function
      | None -> Fmt.string fmt "None"
      | Some Agent_stress.Timeout -> Fmt.string fmt "Some Timeout"
      | Some Agent_stress.Parse_degraded -> Fmt.string fmt "Some Parse_degraded"
      | Some (Agent_stress.Failure_streak n) ->
          Fmt.pf fmt "Some (Failure_streak %d)" n
      | Some Agent_stress.Fallback_approval ->
          Fmt.string fmt "Some Fallback_approval"
      | Some Agent_stress.Task_released -> Fmt.string fmt "Some Task_released"
      | Some (Agent_stress.Turn_failure _) ->
          Fmt.string fmt "Some Turn_failure")
    (fun a b ->
       match (a, b) with
       | None, None -> true
       | Some x, Some y -> kind_eq x y
       | _ -> false)

let classify value =
  Keeper_agent_memory_episode.stress_kind_of_error_kind
    (Memory_oas_bridge.error_kind_of_string value)

let test_oas_timeout_budget_to_timeout () =
  check opt_kind "oas_timeout_budget -> Timeout"
    (Some Agent_stress.Timeout)
    (classify "oas_timeout_budget")

let test_turn_timeout_to_timeout () =
  check opt_kind "turn_timeout -> Timeout"
    (Some Agent_stress.Timeout)
    (classify "turn_timeout");
  check opt_kind "ambiguous_post_commit_timeout -> Timeout"
    (Some Agent_stress.Timeout)
    (classify "ambiguous_post_commit_timeout");
  check opt_kind "autonomous_slot_wait_timeout -> Timeout"
    (Some Agent_stress.Timeout)
    (classify "autonomous_slot_wait_timeout");
  check opt_kind "turn_timeout_after_queue_wait -> Timeout"
    (Some Agent_stress.Timeout)
    (classify "turn_timeout_after_queue_wait")

let test_completion_contract_violation_to_parse_degraded () =
  check opt_kind "completion_contract_violation -> Parse_degraded"
    (Some Agent_stress.Parse_degraded)
    (classify "completion_contract_violation")

let test_unmapped_kinds_return_none () =
  check opt_kind "cascade_exhausted -> None"
    None (classify "cascade_exhausted");
  check opt_kind "no_tool_capable_provider -> None"
    None (classify "no_tool_capable_provider");
  check opt_kind "empty string -> None"
    None (classify "");
  check opt_kind "whitespace -> None"
    None (classify "   ")

let () =
  run "agent_stress_emit_10341"
    [
      ("classifier", [
           test_case "oas_timeout_budget maps to Timeout" `Quick
             test_oas_timeout_budget_to_timeout;
           test_case "*_timeout suffix maps to Timeout" `Quick
             test_turn_timeout_to_timeout;
           test_case "completion_contract_violation maps to Parse_degraded"
             `Quick test_completion_contract_violation_to_parse_degraded;
           test_case "unmapped kinds return None" `Quick
             test_unmapped_kinds_return_none;
         ]);
    ]
