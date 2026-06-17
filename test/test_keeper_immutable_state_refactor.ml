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
