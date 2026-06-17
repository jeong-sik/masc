(** Regression tests for the mutable -> immutable state refactor in
    keeper/runtime subsystems (P9-P12). These exercises are intentionally
    lightweight: they target the pure/stateless surfaces that changed shape
    while preserving behavior. *)

open Alcotest

module KSP = Masc.Keeper_supervisor_self_preservation
module KATH = Masc.Keeper_agent_run_turn_helpers
module ROR = Runtime_oas_runner
module RAC = Runtime_agent_context

(* ── Self-preservation warning thresholds ──────────────────────────────── *)

let test_should_warn_partial_suppression_streak () =
  check bool "streak 1 warns" true
    (KSP.For_testing.should_warn_partial_suppression_streak ~streak:1);
  check bool "streak 9 warns" true
    (KSP.For_testing.should_warn_partial_suppression_streak ~streak:9);
  check bool "streak 2 silent" false
    (KSP.For_testing.should_warn_partial_suppression_streak ~streak:2);
  check bool "streak 10 silent" false
    (KSP.For_testing.should_warn_partial_suppression_streak ~streak:10)
;;

let test_self_preservation_reset_for_test () =
  (* reset_for_test is a no-op on a fresh process; just ensure it does not
     raise and returns unit. *)
  check unit "reset returns unit" () (KSP.reset_for_test ())
;;

let test_update_suppression_streak_increments_same_cohort () =
  KSP.reset_for_test ();
  KSP.For_testing.update_suppression_streak "c1";
  check string "cohort after first update" "c1" (KSP.For_testing.last_dominant_cohort ());
  check int "count after first update" 1 (KSP.For_testing.consecutive_suppressions ());
  KSP.For_testing.update_suppression_streak "c1";
  check int "count after second update" 2 (KSP.For_testing.consecutive_suppressions ());
  KSP.For_testing.update_suppression_streak "c1";
  check int "count after third update" 3 (KSP.For_testing.consecutive_suppressions ())
;;

let test_update_suppression_streak_resets_on_cohort_change () =
  KSP.reset_for_test ();
  KSP.For_testing.update_suppression_streak "c1";
  check string "cohort set" "c1" (KSP.For_testing.last_dominant_cohort ());
  check int "count after first cohort" 1 (KSP.For_testing.consecutive_suppressions ());
  KSP.For_testing.update_suppression_streak "c2";
  check string "cohort changed" "c2" (KSP.For_testing.last_dominant_cohort ());
  check int "count reset on change" 1 (KSP.For_testing.consecutive_suppressions ());
  KSP.For_testing.update_suppression_streak "c2";
  check int "count increments new cohort" 2 (KSP.For_testing.consecutive_suppressions ())
;;

let test_reset_suppression_streak_zeroes_count () =
  KSP.reset_for_test ();
  KSP.For_testing.update_suppression_streak "c1";
  KSP.For_testing.update_suppression_streak "c1";
  KSP.For_testing.update_suppression_streak "c1";
  check int "count before reset" 3 (KSP.For_testing.consecutive_suppressions ());
  KSP.For_testing.reset_suppression_streak ();
  check int "count after reset" 0 (KSP.For_testing.consecutive_suppressions ());
  check string "cohort preserved" "c1" (KSP.For_testing.last_dominant_cohort ())
;;

let test_update_suppression_streak_concurrent () =
  KSP.reset_for_test ();
  let n = 100 in
  let domains =
    List.init 4 (fun _ ->
      Domain.spawn (fun () ->
        for _ = 1 to n do
          KSP.For_testing.update_suppression_streak "c"
        done))
  in
  List.iter Domain.join domains;
  check string "cohort after concurrent updates" "c"
    (KSP.For_testing.last_dominant_cohort ());
  check int "count after concurrent updates" (4 * n)
    (KSP.For_testing.consecutive_suppressions ())
;;

(* ── Link-task idempotency cache (immutable Map + Atomic CAS) ──────────── *)

let test_link_task_cache_mark_and_query () =
  let keeper = "immutable-cache-keeper" in
  let task_id = "task-1" in
  let trace_id = "trace-1" in
  check bool "miss before mark" false
    (KATH.task_link_already_recorded ~keeper ~task_id ~trace_id);
  KATH.mark_task_link ~keeper ~task_id ~trace_id;
  check bool "hit after mark" true
    (KATH.task_link_already_recorded ~keeper ~task_id ~trace_id);
  KATH.mark_task_link ~keeper ~task_id ~trace_id;
  check bool "idempotent mark still hit" true
    (KATH.task_link_already_recorded ~keeper ~task_id ~trace_id);
  check bool "different task misses" false
    (KATH.task_link_already_recorded ~keeper ~task_id:"task-2" ~trace_id);
  check bool "different trace misses" false
    (KATH.task_link_already_recorded ~keeper ~task_id ~trace_id:"trace-2")
;;

(* ── Runtime keeper-name translation (Atomic set-once global) ──────────── *)

let test_runtime_oas_runner_name_translation () =
  ROR.set_keeper_name_xlat
    { keeper_agent_name = (fun k -> k ^ "/agent")
    ; keeper_name_from_agent_name =
        (fun a ->
           if String.length a > 6
           then Some (String.sub a 0 (String.length a - 6))
           else None)
    };
  check (option string) "non-empty keeper maps" (Some "k1/agent")
    (ROR.keeper_agent_name_opt "k1");
  check (option string) "empty keeper returns None" None
    (ROR.keeper_agent_name_opt "  ");
  check (option string) "whitespace trimmed empty" None
    (ROR.keeper_agent_name_opt "")
;;

(* ── Runtime agent context tracer (Atomic global) ──────────────────────── *)

let test_runtime_agent_context_set_oas_tracer () =
  (* The tracer is a set-once Atomic cell used when building agents. The
     public surface only exposes the setter; we verify it is callable. *)
  RAC.set_oas_tracer Agent_sdk.Tracing.null;
  check bool "set_oas_tracer does not raise" true true
;;

(* ── Entrypoint ────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "keeper-immutable-state-refactor"
    [ ( "self-preservation"
      , [ test_case "warn thresholds" `Quick
            test_should_warn_partial_suppression_streak
        ; test_case "reset for test" `Quick test_self_preservation_reset_for_test
        ; test_case "streak increments same cohort" `Quick
            test_update_suppression_streak_increments_same_cohort
        ; test_case "streak resets on cohort change" `Quick
            test_update_suppression_streak_resets_on_cohort_change
        ; test_case "streak reset zeroes count" `Quick
            test_reset_suppression_streak_zeroes_count
        ; test_case "streak increments concurrently" `Quick
            test_update_suppression_streak_concurrent
        ] )
    ; ( "link-task-cache"
      , [ test_case "mark and query" `Quick test_link_task_cache_mark_and_query
        ] )
    ; ( "runtime-name-translation"
      , [ test_case "name translation" `Quick test_runtime_oas_runner_name_translation
        ] )
    ; ( "runtime-agent-context"
      , [ test_case "set tracer" `Quick test_runtime_agent_context_set_oas_tracer
        ] )
    ]
;;
