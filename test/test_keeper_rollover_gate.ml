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

let overflow_blockers_are_recognized () =
  let cases = [
    "Invalid request: Prompt exceeds max length";  (* GLM *)
    "Error: context_length_exceeded";               (* OpenAI *)
    "the prompt is too long to fit in the context window";  (* Ollama *)
    "Anthropic API: prompt too long (200001 > 200000)";     (* Anthropic *)
    "Model exceeded its maximum context length of 8192";    (* variant *)
  ] in
  List.iter
    (fun msg ->
      check bool
        (Printf.sprintf "overflow match: %S" msg)
        true
        (KR.blocker_indicates_overflow msg))
    cases

let non_overflow_blockers_are_not_matched () =
  let cases = [
    "";
    "Internal error: cascade keeper_unified: all models failed";
    "turn outcome ambiguous after committed message";
    "network timeout";
    "rate limited";
  ] in
  List.iter
    (fun msg ->
      check bool
        (Printf.sprintf "no false match: %S" msg)
        false
        (KR.blocker_indicates_overflow msg))
    cases

let gate_skips_when_auto_handoff_disabled () =
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:false
      ~cooldown_elapsed:true
      ~ratio:0.99
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_error
      ~last_blocker:"Prompt exceeds max length"
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
      ~last_blocker:"Prompt exceeds max length"
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
      ~last_blocker:""
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
      ~last_blocker:"Invalid request: Prompt exceeds max length"
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
      ~last_blocker:"context_length_exceeded"
      ()
  in
  check decision_testable "both → ratio+signal"
    (KR.Go "ratio+signal") decision

let gate_requires_error_outcome_for_signal_trigger () =
  (* A blocker string alone isn't enough — the outcome must be Proactive_error.
     Prevents stale blocker from a resolved turn triggering spurious rollover. *)
  let decision =
    KR.classify_rollover_gate
      ~auto_handoff:true
      ~cooldown_elapsed:true
      ~ratio:0.2
      ~handoff_threshold:0.85
      ~last_outcome:KT.Proactive_text_response
      ~last_blocker:"Prompt exceeds max length (stale)"
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
      ~last_blocker:""
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
      ~last_blocker:""
      ~current_turn_overflow_blocker:(Some "Invalid request: Prompt exceeds max length")
      ()
  in
  check decision_testable "current-turn overflow signal fires"
    (KR.Go "persistent_overflow_blocker") decision

let () =
  run "Keeper_rollover.gate" [
    "blocker classification", [
      test_case "overflow strings recognized" `Quick
        overflow_blockers_are_recognized;
      test_case "non-overflow strings rejected" `Quick
        non_overflow_blockers_are_not_matched;
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
    ];
  ]
