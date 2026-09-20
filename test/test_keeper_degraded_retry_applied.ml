(** Degraded-retry "applied" tests, on both surfaces that report it: the
    decision record ([Keeper_unified_turn_types.degraded_retry_applied_for_turn])
    and the execution receipt
    ([Keeper_agent_run_receipt.degraded_retry_taken_up]).

    Reproduces the observed defect. The receipt field [degraded_retry_applied]
    was computed as [Option.is_some turn_state.degraded_retry_info], and that
    field is seeded at [initial_turn_state] from the [deferred_runtime_lane]
    argument — a hint a *previous* turn left behind. No path in the turn writes
    it. So the flag was true on every turn that merely carried a pending hint,
    and an operator reading such a receipt saw a retry that had not happened,
    with a [fallback_reason] derived from the earlier turn's failure rather than
    this turn's.

    Measured on a live keeper receipt at 2026-08-26T16:40Z: the turn's own error
    was an invalid request (a reasoning-effort contract rejection) while the
    receipt read [degraded_retry_applied = true] and
    [fallback_reason = rate_limit]. The reason came from the earlier turn's
    failure, because the receipt's runtime and reason slots were shared between
    the lane the turn was handed and the lane it deferred, with the newer one
    winning.

    Applied means the lane the turn was handed got its turn. A turn does not
    choose: [Keeper_turn_driver.run_named] leads with [deferred_runtime_ids
    hint] on a [Provider_default] contract, which the head-order test below
    pins. What remains is whether the walk reached a provider at all. *)

open Alcotest

module Types = Masc.Keeper_unified_turn_types
module EC = Masc.Keeper_error_classify
module Budget = Masc.Keeper_turn_runtime_budget
module Receipt_finalize = Masc.Keeper_agent_run_receipt
module Driver = Masc.Keeper_turn_driver

let deferred_lane_to next_runtime =
  Some { EC.next_runtime; fallback_reason = EC.Rate_limit }
;;

(* Only [runtime_id] participates in the decision; the budget numbers are
   filler so the record can be built at all. *)
let execution_on runtime_id =
  Some
    { Budget.runtime_id
    ; max_context_resolution =
        { Masc.Keeper_context_runtime.requested_override = None
        ; primary_budget = 200_000
        ; runtime_budget = 200_000
        ; runtime_budget_source = Runtime.Capability
        ; requested_context_window = 200_000
        ; effective_budget = 200_000
        }
    ; max_context = 200_000
    ; temperature = 1.0
    }
;;

(* The measured case. A hint is pending toward the ollama lane, and the turn
   ran on glm — the lane the previous turn had already rotated to. Nothing was
   retried on the hinted lane, so nothing was applied. *)
let test_pending_hint_on_a_different_runtime_is_not_applied () =
  check
    bool
    "a hint toward a lane this turn did not run on is pending, not applied"
    false
    (Types.degraded_retry_applied_for_turn
       ~degraded_retry_info:
         (deferred_lane_to "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731")
       ~last_execution:(execution_on "glm-coding.glm-5-turbo"))
;;

let test_hint_the_turn_ran_on_is_applied () =
  check
    bool
    "the turn ran on the runtime the hint named, so the retry was applied"
    true
    (Types.degraded_retry_applied_for_turn
       ~degraded_retry_info:
         (deferred_lane_to "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731")
       ~last_execution:
         (execution_on "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"))
;;

(* A turn that never reached a provider records no execution. The hint is still
   pending for the next turn, but this turn applied nothing. *)
let test_hint_without_an_execution_is_not_applied () =
  check
    bool
    "no execution means nothing ran, so nothing was applied"
    false
    (Types.degraded_retry_applied_for_turn
       ~degraded_retry_info:(deferred_lane_to "glm-coding.glm-5-turbo")
       ~last_execution:None)
;;

let test_no_hint_is_never_applied () =
  check
    bool
    "with no deferred lane there is no retry to apply"
    false
    (Types.degraded_retry_applied_for_turn
       ~degraded_retry_info:None
       ~last_execution:(execution_on "glm-coding.glm-5-turbo"));
  check
    bool
    "no hint and no execution is still not applied"
    false
    (Types.degraded_retry_applied_for_turn
       ~degraded_retry_info:None
       ~last_execution:None)
;;

(* The same question on the receipt side. [Keeper_unified_turn_execution] used
   to answer it for the receipt with [Option.is_some hint], with no condition
   on the turn having run at all.

   Of the five cases below, one discriminates against that rule: the first,
   where a lane was handed to a turn that reached no provider. The rest hold
   under both rules and are here for what they pin, not for what they catch --
   that a lane reported at all is the one the turn was handed, that it carries
   its own reason rather than the other lane's, that no lane means no report,
   and that the driver walks a deferred lane from its head. The reason half of
   #37108 is not a verdict at all: the two lanes no longer share a runtime and
   reason slot, so no rule can put one lane's reason beside the other's
   runtime. [test_keeper_terminal_reason_typed] pins that shape on the wire. *)

let taken_up ?(provider_reached = Receipt_finalize.Provider_attempt_observed) ~hint () =
  Receipt_finalize.degraded_retry_taken_up ~hint ~provider_reached
;;

let lane_runtime = Alcotest.option Alcotest.string

let runtime_of = Option.map (fun (retry : EC.degraded_retry) -> retry.next_runtime)

(* The reachable half of #37108, and the one main gets wrong. The turn carried
   a lane and ended before any provider answered -- a deferred head that has
   left the catalog reaches exactly this, at [resolve_runtime_candidate_for_attempt]
   in the driver -- so the lane got no turn. Reducing the guard to the hint
   makes this report a retry. *)
let test_receipt_hint_without_a_provider_attempt_is_not_taken_up () =
  check
    lane_runtime
    "a turn that never reached a provider applied no retry"
    None
    (runtime_of
       (taken_up
          ~provider_reached:Receipt_finalize.No_provider_attempt
          ~hint:(deferred_lane_to "glm-coding.glm-5-turbo")
          ()))
;;

let test_receipt_hint_with_a_provider_attempt_is_taken_up () =
  check
    lane_runtime
    "the walk leads with the lane's head, so a turn that reached a provider ran it"
    (Some "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731")
    (runtime_of
       (taken_up
          ~hint:(deferred_lane_to "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731")
          ()))
;;

let test_receipt_no_hint_is_never_taken_up () =
  check
    lane_runtime
    "with no deferred lane there is no retry to apply"
    None
    (runtime_of (taken_up ~hint:None ()));
  check
    lane_runtime
    "and a turn that ran nothing with no lane is still nothing"
    None
    (runtime_of
       (taken_up ~provider_reached:Receipt_finalize.No_provider_attempt ~hint:None ()))
;;

(* The reason travels with the lane it belongs to, so a receipt cannot print
   one turn's failure label beside another turn's runtime. *)
let test_receipt_keeps_the_hints_own_reason () =
  check
    (Alcotest.option Alcotest.string)
    "the applied lane carries the reason it was deferred for"
    (Some "rate_limit")
    (Option.map
       (fun (retry : EC.degraded_retry) ->
          EC.degraded_retry_reason_to_string retry.fallback_reason)
       (taken_up ~hint:(deferred_lane_to "glm-coding.glm-5-turbo") ()))
;;

(* [degraded_retry_taken_up] reports the hint's own runtime because the driver
   walks the lane from its head. That is [deferred_runtime_ids] leading with
   [next_runtime_id]; reorder it and the receipt starts naming a runtime the
   turn did not start on. *)
let test_lane_walk_leads_with_the_deferred_head () =
  let lane =
    Driver.For_testing.make_deferred_runtime_lane
      ~assignment_id:"assignment-1"
      ~failed_runtime_id:"glm-coding.glm-5-turbo"
      ~next_runtime_id:"ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"
      ~later_runtime_ids:[ "kimi.kimi-k3" ]
      ~failure:(Agent_core.Error.Internal "deferred for the test")
  in
  check
    (list string)
    "the lane the driver walks leads with the runtime the hint names"
    [ "ollama_cloud.ollama-cloud-deepseek-v4-flash-0731"; "kimi.kimi-k3" ]
    (Driver.deferred_runtime_ids lane)
;;

let () =
  run
    "keeper_degraded_retry_applied"
    [ ( "applied"
      , [ test_case
            "a pending hint toward another runtime is not applied"
            `Quick
            test_pending_hint_on_a_different_runtime_is_not_applied
        ; test_case
            "a hint the turn ran on is applied"
            `Quick
            test_hint_the_turn_ran_on_is_applied
        ; test_case
            "a hint with no execution is not applied"
            `Quick
            test_hint_without_an_execution_is_not_applied
        ; test_case "no hint is never applied" `Quick test_no_hint_is_never_applied
        ] )
    ; ( "receipt"
      , [ test_case
            "a pending hint toward another runtime is not on the receipt"
            `Quick
            test_receipt_pending_hint_on_another_runtime_is_not_taken_up
        ; test_case
            "the hint the turn dispatched on is on the receipt"
            `Quick
            test_receipt_hint_the_turn_dispatched_on_is_taken_up
        ; test_case
            "a hint on a turn that never dispatched is not on the receipt"
            `Quick
            test_receipt_hint_without_a_dispatch_is_not_taken_up
        ; test_case
            "no hint puts nothing on the receipt"
            `Quick
            test_receipt_no_hint_is_never_taken_up
        ; test_case
            "the applied lane keeps its own reason"
            `Quick
            test_receipt_keeps_the_hints_own_reason
        ; test_case
            "the driver walks the deferred lane from its head"
            `Quick
            test_lane_walk_leads_with_the_deferred_head
        ] )
    ]
;;
