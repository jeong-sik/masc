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
    "applied:tool_heavy"
    (KCP.compaction_decision_to_string (KCP.Applied "tool_heavy"))

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
    (KCP.compaction_decision_applied (KCP.Applied "anything"))

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
    ]
