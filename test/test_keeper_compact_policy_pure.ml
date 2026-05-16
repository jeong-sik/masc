(** Pure-function unit tests for [Keeper_compact_policy].

    Covers the deterministic ADT mappers that don't require a
    [keeper_meta] / [working_context] fixture. *)

open Masc_mcp
module KCP = Keeper_compact_policy

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

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

let test_to_string_skipped_continuity () =
  check_string "Skipped_continuity_reflection includes hold/cooldown"
    "skipped:continuity_reflection(45s<60s)"
    (KCP.compaction_decision_to_string
       (KCP.Skipped_continuity_reflection { hold_s = 45.0; cooldown_sec = 60 }))

let test_to_string_skipped_continuity_zero () =
  check_string "Skipped_continuity_reflection at boundaries"
    "skipped:continuity_reflection(0s<0s)"
    (KCP.compaction_decision_to_string
       (KCP.Skipped_continuity_reflection { hold_s = 0.0; cooldown_sec = 0 }))

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

let test_applied_false_for_skipped_continuity () =
  check_bool "Skipped_continuity_reflection → false" false
    (KCP.compaction_decision_applied
       (KCP.Skipped_continuity_reflection { hold_s = 1.0; cooldown_sec = 1 }))

(* ── threshold constants ─────────────────────────────────────────────── *)

let test_emergency_threshold_in_range () =
  let v = KCP.emergency_compact_ratio_threshold in
  Alcotest.(check bool) "emergency threshold is a meaningful ratio (0,1]"
    true (v > 0.0 && v <= 1.0)

let test_tool_heavy_threshold_positive () =
  Alcotest.(check bool)
    "tool_heavy_msg_threshold > 0" true (KCP.tool_heavy_msg_threshold > 0)

let test_tool_heavy_floor_in_range () =
  let v = KCP.tool_heavy_ratio_floor in
  Alcotest.(check bool) "tool_heavy_ratio_floor is a meaningful ratio [0,1]"
    true (v >= 0.0 && v <= 1.0)

(* ── pure gate decision ─────────────────────────────────────────────── *)

let decide
    ?(ratio = 0.1)
    ?(msg_count = 1)
    ?(tok_count = 1)
    ?(ratio_gate = 0.5)
    ?(message_gate = 0)
    ?(token_gate = 0)
    ?(cooldown_sec = 60)
    ?(last_continuity_update_ts = 0.0)
    ?(last_proactive_ts = 0.0)
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
    ~last_continuity_update_ts
    ~last_proactive_ts
    ~now_ts

let test_decide_ts_zero_bypasses_cooldown () =
  match decide ~ratio:0.6 ~ratio_gate:0.5 ~last_continuity_update_ts:0.0 () with
  | KCP.Applied (Compaction_trigger.Ratio_threshold _) -> ()
  | other ->
    Alcotest.fail
      ("expected ratio compaction, got "
       ^ KCP.compaction_decision_to_string other)

let test_decide_recent_state_blocks_non_emergency () =
  match
    decide
      ~ratio:0.6
      ~ratio_gate:0.5
      ~last_continuity_update_ts:95.0
      ~now_ts:100.0
      ~cooldown_sec:60
      ()
  with
  | KCP.Skipped_continuity_reflection { hold_s; cooldown_sec } ->
    Alcotest.(check int) "cooldown" 60 cooldown_sec;
    Alcotest.(check bool) "hold positive" true (hold_s > 0.0)
  | other ->
    Alcotest.fail
      ("expected continuity skip, got "
       ^ KCP.compaction_decision_to_string other)

let test_decide_emergency_bypasses_cooldown () =
  match
    decide
      ~ratio:KCP.emergency_compact_ratio_threshold
      ~ratio_gate:0.5
      ~last_continuity_update_ts:99.0
      ~now_ts:100.0
      ~cooldown_sec:60
      ()
  with
  | KCP.Applied (Compaction_trigger.Ratio_threshold _) -> ()
  | other ->
    Alcotest.fail
      ("expected emergency ratio compaction, got "
       ^ KCP.compaction_decision_to_string other)

let test_decide_tool_heavy_bypasses_cooldown () =
  match
    decide
      ~ratio:(KCP.tool_heavy_ratio_floor +. 0.01)
      ~msg_count:(KCP.tool_heavy_msg_threshold + 1)
      ~ratio_gate:0.99
      ~message_gate:0
      ~token_gate:0
      ~last_continuity_update_ts:99.0
      ~now_ts:100.0
      ~cooldown_sec:60
      ()
  with
  | KCP.Applied (Compaction_trigger.Tool_heavy _) -> ()
  | other ->
    Alcotest.fail
      ("expected tool-heavy compaction, got "
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
          Alcotest.test_case "Skipped_continuity_reflection 45/60" `Quick
            test_to_string_skipped_continuity;
          Alcotest.test_case "Skipped_continuity_reflection 0/0" `Quick
            test_to_string_skipped_continuity_zero;
        ] );
      ( "compaction_decision_applied",
        [
          Alcotest.test_case "Applied → true" `Quick test_applied_true_for_applied;
          Alcotest.test_case "Blocked → false" `Quick
            test_applied_false_for_blocked;
          Alcotest.test_case "Skipped_no_checkpoint → false" `Quick
            test_applied_false_for_skipped_no_checkpoint;
          Alcotest.test_case "Skipped_continuity → false" `Quick
            test_applied_false_for_skipped_continuity;
        ] );
      ( "thresholds",
        [
          Alcotest.test_case "emergency threshold in (0,1]" `Quick
            test_emergency_threshold_in_range;
          Alcotest.test_case "tool_heavy msg threshold > 0" `Quick
            test_tool_heavy_threshold_positive;
          Alcotest.test_case "tool_heavy ratio in [0,1]" `Quick
            test_tool_heavy_floor_in_range;
        ] );
      ( "decide_compaction",
        [
          Alcotest.test_case "ts=0 bypasses cooldown" `Quick
            test_decide_ts_zero_bypasses_cooldown;
          Alcotest.test_case "recent state blocks non-emergency" `Quick
            test_decide_recent_state_blocks_non_emergency;
          Alcotest.test_case "emergency bypasses cooldown" `Quick
            test_decide_emergency_bypasses_cooldown;
          Alcotest.test_case "tool-heavy bypasses cooldown" `Quick
            test_decide_tool_heavy_bypasses_cooldown;
        ] );
    ]
