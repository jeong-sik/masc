(** Pure-function unit tests for [Keeper_compact_policy].

    Covers the deterministic ADT mappers that don't require a
    [keeper_meta] / [working_context] fixture. *)

open Masc
module KCP = Keeper_compact_policy

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

let test_checkpoint_compaction_uses_summarize_old () =
  let strategies =
    KCP.checkpoint_compaction_strategies ~mode:Keeper_config.Deterministic
    |> List.map Context_compact_oas.strategy_name
  in
  Alcotest.(check (list string))
    "checkpoint compaction summarizes old context before importance pruning"
    [ "PruneToolOutputs"; "MergeContiguous"; "SummarizeOld"; "DropLowImportance" ]
    strategies

(* ── compaction_mode (RFC-0313-adjacent) ─────────────────────────────── *)

(* Floor invariant: the [Llm] plan is a pre-step; both modes share the
   identical deterministic strategy chain as the guaranteed fallback floor.
   If this ever diverges the fallback semantics changed and this test must
   be updated deliberately (not a silent behavior flip). *)
let test_llm_mode_shares_deterministic_floor () =
  let names mode =
    KCP.checkpoint_compaction_strategies ~mode
    |> List.map Context_compact_oas.strategy_name
  in
  Alcotest.(check (list string))
    "Llm mode shares the deterministic fallback chain"
    (names Keeper_config.Deterministic)
    (names Keeper_config.Llm)

(* 38-bug campaign #3: compaction is a judgment call, so the LLM boundary is
   the default; Deterministic is the explicit opt-out. Guards against a
   silent flip back to extractive-only compaction. *)
let test_default_compaction_mode_is_llm () =
  check_string "default compaction mode" "llm"
    (Keeper_config.compaction_mode_to_string Keeper_config.default_compaction_mode)

let test_compaction_mode_parse_canonical () =
  let parse raw =
    match Keeper_config.compaction_mode_of_string raw with
    | Ok m -> Keeper_config.compaction_mode_to_string m
    | Error e -> "error:" ^ e
  in
  check_string "deterministic canonical" "deterministic" (parse "deterministic");
  check_string "extractive alias → deterministic" "deterministic" (parse "EXTRACTIVE");
  check_string "llm canonical" "llm" (parse "llm");
  check_string "summarizer alias → llm" "llm" (parse " Summarizer ")

let test_compaction_mode_parse_unknown_is_error () =
  match Keeper_config.compaction_mode_of_string "aggressive" with
  | Ok _ -> Alcotest.fail "unknown compaction_mode must not parse to a mode"
  | Error msg ->
    Alcotest.(check bool)
      "unknown mode error names the input" true
      (Astring.String.is_infix ~affix:"aggressive" msg)

(* ── compaction_decision_to_string ───────────────────────────────────── *)

let test_to_string_applied () =
  check_string "Applied carries reason"
    "applied:manual"
    (KCP.compaction_decision_to_string (KCP.Applied Compaction_trigger.Manual))

let test_to_string_blocked () =
  check_string "Blocked_below_thresholds"
    "blocked:below_thresholds"
    (KCP.compaction_decision_to_string KCP.Blocked_below_thresholds)

let test_to_string_skipped_no_checkpoint () =
  check_string "Skipped_no_checkpoint"
    "skipped:no_checkpoint"
    (KCP.compaction_decision_to_string KCP.Skipped_no_checkpoint)

let test_to_string_skipped_cooldown () =
  check_string "Skipped_cooldown includes hold/cooldown"
    "skipped:cooldown(45s<60s)"
    (KCP.compaction_decision_to_string
       (KCP.Skipped_cooldown { hold_s = 45.0; cooldown_sec = 60 }))

let test_to_string_skipped_cooldown_zero () =
  check_string "Skipped_cooldown at boundaries"
    "skipped:cooldown(0s<0s)"
    (KCP.compaction_decision_to_string
       (KCP.Skipped_cooldown { hold_s = 0.0; cooldown_sec = 0 }))

(* ── compaction_decision_applied ─────────────────────────────────────── *)

let test_applied_true_for_applied () =
  check_bool "Applied → true" true
    (KCP.compaction_decision_applied (KCP.Applied Compaction_trigger.Manual))

let test_applied_false_for_blocked () =
  check_bool "Blocked_below_thresholds → false" false
    (KCP.compaction_decision_applied KCP.Blocked_below_thresholds)

let test_applied_false_for_skipped_no_checkpoint () =
  check_bool "Skipped_no_checkpoint → false" false
    (KCP.compaction_decision_applied KCP.Skipped_no_checkpoint)

let test_applied_false_for_skipped_cooldown () =
  check_bool "Skipped_cooldown → false" false
    (KCP.compaction_decision_applied
       (KCP.Skipped_cooldown { hold_s = 1.0; cooldown_sec = 1 }))

(* ── threshold constants ─────────────────────────────────────────────── *)

let test_emergency_threshold_in_range () =
  let v = KCP.emergency_compact_ratio_threshold in
  Alcotest.(check bool) "emergency threshold is a meaningful ratio (0,1]"
    true (v > 0.0 && v <= 1.0)

(* ── pure gate decision ─────────────────────────────────────────────── *)

let decide
    ?(ratio = 0.1)
    ?(msg_count = 1)
    ?(tok_count = 1)
    ?(ratio_gate = 0.5)
    ?(message_gate = 0)
    ?(token_gate = 0)
    ?(cooldown_sec = 60)
    ?(last_compaction_ts = 0.0)
    ?(now_ts = 100.0)
    () =
  KCP.decide_compaction
    ~ratio
    ~msg_count
    ~tok_count
    ~ratio_gate
    ~message_gate
    ~token_gate
    ~cooldown_sec
    ~last_compaction_ts
    ~now_ts

let test_decide_ts_zero_bypasses_cooldown () =
  match decide ~ratio:0.6 ~ratio_gate:0.5 ~last_compaction_ts:0.0 () with
  | KCP.Applied (Compaction_trigger.Ratio_threshold _) -> ()
  | other ->
    Alcotest.fail
      ("expected ratio compaction, got "
       ^ KCP.compaction_decision_to_string other)

let test_decide_recent_compaction_blocks_non_emergency () =
  match
    decide
      ~ratio:0.6
      ~ratio_gate:0.5
      ~last_compaction_ts:95.0
      ~now_ts:100.0
      ~cooldown_sec:60
      ()
  with
  | KCP.Skipped_cooldown { hold_s; cooldown_sec } ->
    Alcotest.(check int) "cooldown" 60 cooldown_sec;
    Alcotest.(check bool) "hold positive" true (hold_s > 0.0)
  | other ->
    Alcotest.fail
      ("expected cooldown skip, got "
       ^ KCP.compaction_decision_to_string other)

let test_decide_emergency_bypasses_cooldown () =
  match
    decide
      ~ratio:KCP.emergency_compact_ratio_threshold
      ~ratio_gate:0.5
      ~last_compaction_ts:99.0
      ~now_ts:100.0
      ~cooldown_sec:60
      ()
  with
  | KCP.Applied (Compaction_trigger.Ratio_threshold _) -> ()
  | other ->
    Alcotest.fail
      ("expected emergency ratio compaction, got "
       ^ KCP.compaction_decision_to_string other)

(* Regression for the removed tool_heavy trigger: the production churn
   profile (fleet logs 2026-06-10: tech_glutton msgs=67, ratio=0.2695,
   default gates ratio=0.85 / message=disabled / token=196608) compacted
   every 2-9 minutes via tool_heavy.  With the trigger gone the same
   state must NOT compact once the reflection cooldown is satisfied. *)
let test_decide_tool_heavy_profile_blocked () =
  match
    decide
      ~ratio:0.2695
      ~msg_count:67
      ~tok_count:17246
      ~ratio_gate:0.85
      ~message_gate:0
      ~token_gate:196608
      ~last_compaction_ts:0.0
      ~now_ts:100.0
      ~cooldown_sec:15
      ()
  with
  | KCP.Blocked_below_thresholds -> ()
  | other ->
    Alcotest.fail
      ("expected no compaction for tool-heavy-but-low-pressure state, got "
       ^ KCP.compaction_decision_to_string other)

(* The cooldown skip must hold even at high message counts: only the
   emergency ratio floor bypasses it. *)
let test_decide_tool_heavy_profile_respects_cooldown () =
  match
    decide
      ~ratio:0.2695
      ~msg_count:67
      ~ratio_gate:0.25 (* below current ratio: gate would fire if ready *)
      ~last_compaction_ts:99.0
      ~now_ts:100.0
      ~cooldown_sec:60
      ()
  with
  | KCP.Skipped_cooldown _ -> ()
  | other ->
    Alcotest.fail
      ("expected cooldown skip at high msg_count, got "
       ^ KCP.compaction_decision_to_string other)

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_compact_policy_pure"
    [
      ( "compaction_decision_to_string",
        [
          Alcotest.test_case "Applied" `Quick test_to_string_applied;
          Alcotest.test_case "Blocked_below_thresholds" `Quick
            test_to_string_blocked;
          Alcotest.test_case "Skipped_no_checkpoint" `Quick
            test_to_string_skipped_no_checkpoint;
          Alcotest.test_case "Skipped_cooldown 45/60" `Quick
            test_to_string_skipped_cooldown;
          Alcotest.test_case "Skipped_cooldown 0/0" `Quick
            test_to_string_skipped_cooldown_zero;
        ] );
      ( "compaction_decision_applied",
        [
          Alcotest.test_case "Applied → true" `Quick test_applied_true_for_applied;
          Alcotest.test_case "Blocked → false" `Quick
            test_applied_false_for_blocked;
          Alcotest.test_case "Skipped_no_checkpoint → false" `Quick
            test_applied_false_for_skipped_no_checkpoint;
          Alcotest.test_case "Skipped_cooldown → false" `Quick
            test_applied_false_for_skipped_cooldown;
        ] );
      ( "thresholds",
        [
          Alcotest.test_case "emergency threshold in (0,1]" `Quick
            test_emergency_threshold_in_range;
        ] );
      ( "strategies",
        [
          Alcotest.test_case "checkpoint compaction summarizes old context"
            `Quick test_checkpoint_compaction_uses_summarize_old;
          Alcotest.test_case "Llm mode shares the deterministic floor"
            `Quick test_llm_mode_shares_deterministic_floor;
        ] );
      ( "compaction_mode",
        [
          Alcotest.test_case "default mode is llm" `Quick
            test_default_compaction_mode_is_llm;
          Alcotest.test_case "canonical + alias parse" `Quick
            test_compaction_mode_parse_canonical;
          Alcotest.test_case "unknown mode is a config error" `Quick
            test_compaction_mode_parse_unknown_is_error;
        ] );
      ( "decide_compaction",
        [
          Alcotest.test_case "ts=0 bypasses cooldown" `Quick
            test_decide_ts_zero_bypasses_cooldown;
          Alcotest.test_case "recent compaction blocks non-emergency" `Quick
            test_decide_recent_compaction_blocks_non_emergency;
          Alcotest.test_case "emergency bypasses cooldown" `Quick
            test_decide_emergency_bypasses_cooldown;
          Alcotest.test_case "churn profile no longer compacts" `Quick
            test_decide_tool_heavy_profile_blocked;
          Alcotest.test_case "high msg_count respects cooldown" `Quick
            test_decide_tool_heavy_profile_respects_cooldown;
        ] );
    ]
