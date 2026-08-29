(** [degraded_retry_applied_for_turn] tests.

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
    [fallback_reason = rate_limit]. The dashboard consequence is in
    [dashboard/src/components/fsm-hub.ts], which renders "retry applied" versus
    "retry queued" off this flag — the second branch was unreachable, because
    the flag was true exactly when the runtime it prints alongside was present.

    Applied means this turn ran on the runtime the hint named. *)

open Alcotest

module Types = Masc.Keeper_unified_turn_types
module EC = Masc.Keeper_error_classify
module Budget = Masc.Keeper_turn_runtime_budget

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
        ; runtime_budget_source = None
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
    ]
;;
