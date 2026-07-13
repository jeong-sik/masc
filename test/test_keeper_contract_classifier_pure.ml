(** Pure-function unit tests for [Keeper_contract_classifier].

    Covers the actionable-signal label mapper, the [is_actionable] projection,
    and [classify_actionable_signal] precedence (unclaimed_tasks >
    board_activity). *)

open Masc
module KCC = Keeper_contract_classifier

let check_string label expected actual =
  Alcotest.(check string) label expected actual

let check_bool label expected actual =
  Alcotest.(check bool) label expected actual

(* Helper to build a [world_observation] with named fields. *)
let make_obs ~tasks ~board : KCC.world_observation =
  {
    unclaimed_task_count = tasks;
    board_activity_count = board;
  }

let signal_testable : KCC.actionable_signal Alcotest.testable =
  Alcotest.testable
    (fun fmt s -> Format.fprintf fmt "%s" (KCC.actionable_signal_label s))
    ( = )

let check_signal label expected actual =
  Alcotest.check signal_testable label expected actual

(* ── actionable_signal_label ─────────────────────────────────────────── *)

let test_signal_label_unclaimed () =
  check_string "Has_unclaimed_tasks" "has_unclaimed_tasks"
    (KCC.actionable_signal_label KCC.Has_unclaimed_tasks)

let test_signal_label_board () =
  check_string "Has_board_activity" "has_board_activity"
    (KCC.actionable_signal_label KCC.Has_board_activity)

let test_signal_label_none () =
  check_string "No_actionable_signal" "no_actionable_signal"
    (KCC.actionable_signal_label KCC.No_actionable_signal)

(* ── is_actionable ────────────────────────────────────────────────────── *)

let test_is_actionable_unclaimed () =
  check_bool "Has_unclaimed_tasks is actionable" true
    (KCC.is_actionable KCC.Has_unclaimed_tasks)

let test_is_actionable_board () =
  check_bool "Has_board_activity is actionable" true
    (KCC.is_actionable KCC.Has_board_activity)

let test_is_actionable_none () =
  check_bool "No_actionable_signal is NOT actionable" false
    (KCC.is_actionable KCC.No_actionable_signal)

(* ── classify_actionable_signal: precedence ───────────────────────────── *)

let test_classify_unclaimed_wins_over_board () =
  let o = make_obs ~tasks:1 ~board:5 in
  check_signal "tasks beat board" KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal o)

let test_classify_board_signal () =
  let o = make_obs ~tasks:0 ~board:1 in
  check_signal "board signal" KCC.Has_board_activity
    (KCC.classify_actionable_signal o)

let test_classify_none () =
  let o = make_obs ~tasks:0 ~board:0 in
  check_signal "no signal" KCC.No_actionable_signal
    (KCC.classify_actionable_signal o)

(* ── runner ──────────────────────────────────────────────────────────── *)

let () =
  Alcotest.run "Keeper_contract_classifier_pure"
    [
      ( "actionable_signal_label",
        [
          Alcotest.test_case "Has_unclaimed_tasks" `Quick test_signal_label_unclaimed;
          Alcotest.test_case "Has_board_activity" `Quick test_signal_label_board;
          Alcotest.test_case "No_actionable_signal" `Quick test_signal_label_none;
        ] );
      ( "is_actionable",
        [
          Alcotest.test_case "unclaimed → true" `Quick test_is_actionable_unclaimed;
          Alcotest.test_case "board → true" `Quick test_is_actionable_board;
          Alcotest.test_case "none → false" `Quick test_is_actionable_none;
        ] );
      ( "classify_actionable_signal precedence",
        [
          Alcotest.test_case "tasks > board" `Quick
            test_classify_unclaimed_wins_over_board;
          Alcotest.test_case "board signal" `Quick test_classify_board_signal;
          Alcotest.test_case "no signal" `Quick test_classify_none;
        ] );
    ]
