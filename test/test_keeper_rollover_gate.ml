(** Tests for the pure rollover gate decision.

    Covers the signal-driven handoff trigger that resolves umbrella #7036
    (keeper fleet stuck in error loop with compaction_count >> generation). *)

open Alcotest

module KR = Masc_mcp.Keeper_exec_context
module KT = Masc_mcp.Keeper_types

let decision_testable =
  let pp fmt = function
    | KR.Skip reason -> Format.fprintf fmt "Skip(%s)" reason
    | KR.Go reason -> Format.fprintf fmt "Go(%s)" reason
  in
  let eq a b =
    match a, b with
    | KR.Skip x, KR.Skip y | KR.Go x, KR.Go y -> String.equal x y
    | _ -> false
  in
  testable pp eq

(* Provider/model are opaque aliases at the keeper layer.  These tests pin the
   typed [blocker_class] contract — the SDK boundary
   ([Keeper_status_bridge.blocker_class_of_sdk_error] /
   [blocker_class_of_string]) is responsible for translating wire-level
   phrasing into the typed enum once.  Downstream rollover never sees the
   detail string. *)

let overflow_class_is_recognized () =
  check bool "Sdk_token_budget_exceeded → overflow"
    true
    (KR.blocker_class_indicates_overflow KT.Sdk_token_budget_exceeded)

let non_overflow_classes_are_not_matched () =
  (* Exhaustive: every variant other than [Sdk_token_budget_exceeded] is
     not an overflow signal.  Adding a new [blocker_class] variant forces
     a compile error in [Keeper_rollover.blocker_class_indicates_overflow]
     — the catch-all is intentionally omitted. *)
  let cases : KT.blocker_class list = [
    KT.Cascade_exhausted KT.No_providers_available;
    KT.Cascade_exhausted KT.All_providers_failed;
    KT.Cascade_exhausted KT.Max_turns_exceeded;
    KT.Ambiguous_post_commit_timeout;
    KT.Ambiguous_post_commit_failure;
    KT.Autonomous_slot_wait_timeout;
    KT.Admission_queue_wait_timeout;
    KT.Turn_timeout_after_queue_wait;
    KT.Oas_timeout_budget;
    KT.Turn_timeout;
    KT.Completion_contract_violation;
    KT.No_tool_capable_provider;
    KT.Fiber_unresolved;
    KT.Stale_turn_timeout;
    KT.Stale_fleet_batch;
    KT.Sdk_max_turns_exceeded;
    KT.Sdk_cost_budget_exceeded;
    KT.Sdk_unrecognized_stop_reason;
    KT.Sdk_idle_detected;
    KT.Sdk_tool_retry_exhausted;
    KT.Sdk_guardrail_violation;
    KT.Sdk_tripwire_violation;
    KT.Sdk_exit_condition_met;
  ] in
  List.iter
    (fun klass ->
      check bool
        (Printf.sprintf "non-overflow class: %s"
           (KT.blocker_class_to_string klass))
        false
        (KR.blocker_class_indicates_overflow klass))
    cases

(* Test fixtures for the typed blocker_info inputs.  Detail strings are
   intentionally redacted to placeholder text — the gate semantics depend
   only on [klass]. *)
let overflow_info : KT.blocker_info =
  { klass = KT.Sdk_token_budget_exceeded; detail = "<opaque-detail>" }

let non_overflow_info : KT.blocker_info =
  { klass = KT.Sdk_max_turns_exceeded; detail = "<opaque-detail>" }

let gate_skips_when_auto_handoff_disabled () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:false
      ~cooldown_elapsed:true
      ~ratio:0.99
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_error
      ~last_blocker_info:(Some overflow_info)
      ()
  in
  check decision_testable "disabled → Skip"
    (KR.Skip "auto_handoff_disabled") decision

let gate_skips_when_cooldown_active () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:false
      ~ratio:0.99
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_error
      ~last_blocker_info:(Some overflow_info)
      ()
  in
  check decision_testable "cooldown → Skip" (KR.Skip "cooldown") decision

let gate_fires_on_ratio () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.90
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_silent
      ~last_blocker_info:None
      ()
  in
  check decision_testable "ratio gate" (KR.Go "ratio") decision

let gate_fires_on_persistent_overflow_despite_low_ratio () =
  (* This is the umbrella #7036 masc-improver scenario:
     checkpoint ratio stays at 4.5% because compaction shrinks the snapshot,
     but the real prompt (context_injector-assembled) exceeds model max.
     The ratio-only gate structurally cannot fire; the signal gate must. *)
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.045  (* masc-improver snapshot 2026-04-14 *)
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_error
      ~last_blocker_info:(Some overflow_info)
      ()
  in
  check decision_testable "signal gate fires despite low ratio"
    (KR.Go "persistent_overflow_blocker") decision

let gate_reports_both_when_both_conditions_true () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.90
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_error
      ~last_blocker_info:(Some overflow_info)
      ()
  in
  check decision_testable "both → ratio+signal"
    (KR.Go "ratio+signal") decision

let gate_requires_error_outcome_for_signal_trigger () =
  (* A blocker class alone isn't enough — the outcome must be Proactive_error.
     Prevents stale blocker from a resolved turn triggering spurious rollover. *)
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.2
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_text_response
      ~last_blocker_info:(Some overflow_info)
      ()
  in
  check decision_testable "stale blocker without error → Skip"
    (KR.Skip "below_thresholds") decision

let gate_skips_below_all_thresholds () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.10
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_silent
      ~last_blocker_info:None
      ()
  in
  check decision_testable "all quiet → Skip"
    (KR.Skip "below_thresholds") decision

let gate_fires_on_current_turn_overflow_signal () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.10
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_text_response
      ~last_blocker_info:None
      ~current_turn_blocker_info:(Some overflow_info)
      ()
  in
  check decision_testable "current-turn overflow signal fires"
    (KR.Go "persistent_overflow_blocker") decision

let gate_ignores_non_overflow_class_signal () =
  (* Boundary contract: a non-overflow class (e.g. Sdk_max_turns_exceeded)
     must NOT trigger an overflow-driven rollover even when stamped on the
     current turn.  This pins the semantic difference between substring
     match (loose) and typed class (precise). *)
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.10
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_error
      ~last_blocker_info:(Some non_overflow_info)
      ~current_turn_blocker_info:(Some non_overflow_info)
      ()
  in
  check decision_testable "non-overflow class → Skip"
    (KR.Skip "below_thresholds") decision

let () =
  run "Keeper_rollover.gate" [
    "blocker classification", [
      test_case "Sdk_token_budget_exceeded recognized as overflow" `Quick
        overflow_class_is_recognized;
      test_case "non-overflow classes rejected (exhaustive)" `Quick
        non_overflow_classes_are_not_matched;
    ];
    "gate decisions", [
      test_case "skip when auto_handoff disabled" `Quick
        gate_skips_when_auto_handoff_disabled;
      test_case "skip when cooldown active" `Quick
        gate_skips_when_cooldown_active;
      test_case "fires on ratio alone" `Quick
        gate_fires_on_ratio;
      test_case "fires on persistent overflow despite low ratio (#7036)" `Quick
        gate_fires_on_persistent_overflow_despite_low_ratio;
      test_case "reports ratio+signal when both true" `Quick
        gate_reports_both_when_both_conditions_true;
      test_case "fires on current-turn overflow signal" `Quick
        gate_fires_on_current_turn_overflow_signal;
      test_case "requires error outcome for signal trigger" `Quick
        gate_requires_error_outcome_for_signal_trigger;
      test_case "skip below all thresholds" `Quick
        gate_skips_below_all_thresholds;
      test_case "non-overflow class signal does not fire rollover" `Quick
        gate_ignores_non_overflow_class_signal;
    ];
  ]
