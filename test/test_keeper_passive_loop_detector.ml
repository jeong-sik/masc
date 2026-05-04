(** Tests for Keeper_passive_loop_detector (#12799).

    Pure unit tests for the streak counter, detection latch, and reset.
    No Eio fibers needed — the module uses Eio.Mutex but Eio_main.run wraps
    each test that exercises concurrent access. *)

open Alcotest
module PLD = Masc_mcp.Keeper_passive_loop_detector
module P = Masc_mcp.Prometheus

(* ── Helpers ──────────────────────────────────────────────────────── *)

let setup () = PLD.reset_all_for_test ()

(* ── Tests ──────────────────────────────────────────────────────────── *)

let test_initial_streak_zero () =
  setup ();
  check int "no-state keeper streak = 0" 0
    (PLD.current_streak ~keeper_name:"k1")

let test_passive_increments_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  check int "2 passives → streak 2" 2
    (PLD.current_streak ~keeper_name:"k1")

let test_claim_context_increments_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"claim_context";
  check int "claim_context increments" 1
    (PLD.current_streak ~keeper_name:"k1")

let test_execution_resets_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"execution";
  check int "execution resets streak to 0" 0
    (PLD.current_streak ~keeper_name:"k1")

let test_completion_resets_streak () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k1" ~progress_class:"completion";
  check int "completion resets streak to 0" 0
    (PLD.current_streak ~keeper_name:"k1")

let test_detection_fires_metric_at_threshold () =
  Eio_main.run @@ fun _env ->
  setup ();
  (* Default threshold is 5. Fire exactly 5 passive turns and check metric. *)
  let before =
    P.metric_value_or_zero
      P.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-metric")] ()
  in
  for _ = 1 to 5 do
    PLD.record_turn ~keeper_name:"k-metric" ~progress_class:"passive_status"
  done;
  let after =
    P.metric_value_or_zero
      P.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-metric")] ()
  in
  check bool "metric incremented at threshold" true (after > before)

let test_detection_latch_does_not_double_fire () =
  Eio_main.run @@ fun _env ->
  setup ();
  let before =
    P.metric_value_or_zero
      P.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-latch")] ()
  in
  (* Fire well above threshold — latch should prevent repeated increments *)
  for _ = 1 to 20 do
    PLD.record_turn ~keeper_name:"k-latch" ~progress_class:"passive_status"
  done;
  let after =
    P.metric_value_or_zero
      P.metric_keeper_passive_loop_detected_total
      ~labels:[("keeper", "k-latch")] ()
  in
  check (float 0.001) "latch: counter increments exactly once per episode"
    (before +. 1.0) after

let test_reset_clears_state () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"k-reset" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"k-reset" ~progress_class:"passive_status";
  PLD.reset ~keeper_name:"k-reset";
  check int "after reset streak = 0" 0
    (PLD.current_streak ~keeper_name:"k-reset")

let test_independent_keepers () =
  Eio_main.run @@ fun _env ->
  setup ();
  PLD.record_turn ~keeper_name:"ka" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"ka" ~progress_class:"passive_status";
  PLD.record_turn ~keeper_name:"kb" ~progress_class:"execution";
  check int "ka streak unaffected by kb" 2
    (PLD.current_streak ~keeper_name:"ka");
  check int "kb streak = 0 (execution)" 0
    (PLD.current_streak ~keeper_name:"kb")

let () =
  run "keeper_passive_loop_detector" [
    "streak", [
      test_case "initial streak = 0" `Quick test_initial_streak_zero;
      test_case "passive_status increments streak" `Quick
        test_passive_increments_streak;
      test_case "claim_context increments streak" `Quick
        test_claim_context_increments_streak;
      test_case "execution resets streak" `Quick
        test_execution_resets_streak;
      test_case "completion resets streak" `Quick
        test_completion_resets_streak;
    ];
    "detection", [
      test_case "metric fires at threshold" `Quick
        test_detection_fires_metric_at_threshold;
      test_case "latch prevents double-fire per episode" `Quick
        test_detection_latch_does_not_double_fire;
    ];
    "reset", [
      test_case "reset clears streak" `Quick test_reset_clears_state;
    ];
    "independence", [
      test_case "keepers are tracked independently" `Quick
        test_independent_keepers;
    ];
  ]
