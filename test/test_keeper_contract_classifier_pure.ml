(** Pure-function unit tests for [Keeper_contract_classifier].

    Covers the actionable-signal label mapper and
    [classify_actionable_signal] precedence (unclaimed_tasks >
    completion_authority_rejection > board_activity). *)

open Masc
module KCC = Keeper_contract_classifier

let check_string label expected actual =
  Alcotest.(check string) label expected actual

(* Helper to build a [world_observation] with named fields. *)
let make_obs ?(rejections = 0) ?(cancellations = 0) ~tasks ~board ()
  : KCC.world_observation =
  {
    unclaimed_task_count = tasks;
    board_activity_count = board;
    completion_authority_rejection_count = rejections;
    task_cancellation_count = cancellations;
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

let test_signal_label_completion_authority_rejection () =
  check_string
    "Has_completion_authority_rejection"
    "has_completion_authority_rejection"
    (KCC.actionable_signal_label KCC.Has_completion_authority_rejection)

let test_signal_label_none () =
  check_string "No_actionable_signal" "no_actionable_signal"
    (KCC.actionable_signal_label KCC.No_actionable_signal)

(* ── classify_actionable_signal: precedence ───────────────────────────── *)

let test_classify_unclaimed_wins_over_board () =
  let o = make_obs ~tasks:1 ~board:5 () in
  check_signal "tasks beat board" KCC.Has_unclaimed_tasks
    (KCC.classify_actionable_signal o)

let test_classify_board_signal () =
  let o = make_obs ~tasks:0 ~board:1 () in
  check_signal "board signal" KCC.Has_board_activity
    (KCC.classify_actionable_signal o)

let test_classify_completion_authority_rejection () =
  let o = make_obs ~tasks:0 ~board:1 ~rejections:1 () in
  check_signal
    "completion authority rejection is separate from board"
    KCC.Has_completion_authority_rejection
    (KCC.classify_actionable_signal o)

let test_classify_none () =
  let o = make_obs ~tasks:0 ~board:0 () in
  check_signal "no signal" KCC.No_actionable_signal
    (KCC.classify_actionable_signal o)

(* ── runner ──────────────────────────────────────────────────────────── *)

(* A turn woken only by a cancellation of a Task this Keeper authored had no
   count of its own, and cancellations are deliberately excluded from Board
   activity because no Board post backs them. The receipt therefore recorded
   "no_actionable_signal" for a turn that ran precisely because of one. *)
let test_classify_cancellation_alone_is_actionable () =
  check_signal "cancellation alone" KCC.Has_task_cancellation
    (KCC.classify_actionable_signal
       (make_obs ~tasks:0 ~board:0 ~cancellations:1 ()))

let test_classify_cancellation_outranks_board () =
  check_signal "cancellation > board" KCC.Has_task_cancellation
    (KCC.classify_actionable_signal
       (make_obs ~tasks:0 ~board:3 ~cancellations:1 ()))

let test_classify_rejection_outranks_cancellation () =
  check_signal "rejection > cancellation" KCC.Has_completion_authority_rejection
    (KCC.classify_actionable_signal
       (make_obs ~tasks:0 ~board:0 ~rejections:1 ~cancellations:1 ()))

let test_signal_label_cancellation () =
  check_string "Has_task_cancellation" "has_task_cancellation"
    (KCC.actionable_signal_label KCC.Has_task_cancellation)

let () =
  Alcotest.run "Keeper_contract_classifier_pure"
    [
      ( "actionable_signal_label",
        [
          Alcotest.test_case "Has_unclaimed_tasks" `Quick test_signal_label_unclaimed;
          Alcotest.test_case "Has_board_activity" `Quick test_signal_label_board;
          Alcotest.test_case "Has_completion_authority_rejection" `Quick
            test_signal_label_completion_authority_rejection;
          Alcotest.test_case "Has_task_cancellation" `Quick
            test_signal_label_cancellation;
          Alcotest.test_case "No_actionable_signal" `Quick test_signal_label_none;
        ] );
      ( "classify_actionable_signal precedence",
        [
          Alcotest.test_case "tasks > board" `Quick
            test_classify_unclaimed_wins_over_board;
          Alcotest.test_case "board signal" `Quick test_classify_board_signal;
          Alcotest.test_case "completion authority rejection" `Quick
            test_classify_completion_authority_rejection;
          Alcotest.test_case "cancellation alone is actionable" `Quick
            test_classify_cancellation_alone_is_actionable;
          Alcotest.test_case "cancellation > board" `Quick
            test_classify_cancellation_outranks_board;
          Alcotest.test_case "rejection > cancellation" `Quick
            test_classify_rejection_outranks_cancellation;
          Alcotest.test_case "no signal" `Quick test_classify_none;
        ] );
    ]
