(* test/test_stay_silent_loop_detector.ml

   #9926: detector observability contract. Pins:
   - Streak increments on consecutive "stay_silent" speech_act
   - Streak resets to 0 on any non-stay_silent act
   - Detected-counter only bumps once per loop episode (latched)
   - Reset latches on streak reset
   - Threshold env var honored
   - Per-keeper isolation *)

module D = Masc_mcp.Keeper_stay_silent_loop_detector
module Prom = Masc_mcp.Prometheus

(* Detector now uses Eio.Mutex (was Stdlib.Mutex; the latter raised EDEADLK
   under any fiber contention). Every public entry needs an Eio fiber
   context, so wrap each Alcotest body in Eio_main.run. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

let detected_count keeper =
  Prom.metric_value_or_zero
    "masc_keeper_stay_silent_loop_detected_total"
    ~labels:[ ("keeper", keeper) ] ()

let set_threshold n =
  Unix.putenv "MASC_STAY_SILENT_LOOP_THRESHOLD" (string_of_int n)

let clear_threshold () =
  Unix.putenv "MASC_STAY_SILENT_LOOP_THRESHOLD" ""

let test_streak_increments () =
  D.reset_all_for_test ();
  let k = "test-keeper-increments" in
  D.record_turn ~keeper_name:k ~speech_act:"stay_silent";
  Alcotest.(check int) "after 1" 1 (D.current_streak ~keeper_name:k);
  D.record_turn ~keeper_name:k ~speech_act:"stay_silent";
  D.record_turn ~keeper_name:k ~speech_act:"stay_silent";
  Alcotest.(check int) "after 3" 3 (D.current_streak ~keeper_name:k)

let test_any_other_act_resets () =
  D.reset_all_for_test ();
  let k = "test-keeper-resets" in
  for _ = 1 to 5 do
    D.record_turn ~keeper_name:k ~speech_act:"stay_silent"
  done;
  Alcotest.(check int) "pre-reset" 5 (D.current_streak ~keeper_name:k);
  D.record_turn ~keeper_name:k ~speech_act:"declare";
  Alcotest.(check int) "after declare" 0 (D.current_streak ~keeper_name:k);
  D.record_turn ~keeper_name:k ~speech_act:"stay_silent";
  Alcotest.(check int) "after new stay_silent" 1
    (D.current_streak ~keeper_name:k)

let test_threshold_crossing_fires_counter () =
  D.reset_all_for_test ();
  let k = "test-keeper-threshold-fires" in
  set_threshold 3;
  let before = detected_count k in
  for _ = 1 to 2 do
    D.record_turn ~keeper_name:k ~speech_act:"stay_silent"
  done;
  Alcotest.(check (float 0.0001)) "no fire at 2" before
    (detected_count k);
  D.record_turn ~keeper_name:k ~speech_act:"stay_silent";
  Alcotest.(check (float 0.0001)) "fires at 3"
    (before +. 1.0) (detected_count k);
  clear_threshold ()

let test_latched_no_repeat_while_streak_grows () =
  D.reset_all_for_test ();
  let k = "test-keeper-latched" in
  set_threshold 3;
  let before = detected_count k in
  for _ = 1 to 10 do
    D.record_turn ~keeper_name:k ~speech_act:"stay_silent"
  done;
  Alcotest.(check (float 0.0001)) "latched: exactly +1 across 10 stay_silent"
    (before +. 1.0) (detected_count k);
  clear_threshold ()

let test_latch_releases_on_reset_then_refires () =
  D.reset_all_for_test ();
  let k = "test-keeper-relatch" in
  set_threshold 3;
  let before = detected_count k in
  for _ = 1 to 5 do
    D.record_turn ~keeper_name:k ~speech_act:"stay_silent"
  done;
  Alcotest.(check (float 0.0001)) "first loop fires once"
    (before +. 1.0) (detected_count k);
  (* Break the loop with a non-stay_silent act. *)
  D.record_turn ~keeper_name:k ~speech_act:"declare";
  (* Start a second loop. *)
  for _ = 1 to 5 do
    D.record_turn ~keeper_name:k ~speech_act:"stay_silent"
  done;
  Alcotest.(check (float 0.0001)) "second loop fires once more"
    (before +. 2.0) (detected_count k);
  clear_threshold ()

let test_per_keeper_isolation () =
  D.reset_all_for_test ();
  let a = "test-keeper-A" in
  let b = "test-keeper-B" in
  for _ = 1 to 4 do
    D.record_turn ~keeper_name:a ~speech_act:"stay_silent"
  done;
  D.record_turn ~keeper_name:b ~speech_act:"stay_silent";
  Alcotest.(check int) "A streak" 4 (D.current_streak ~keeper_name:a);
  Alcotest.(check int) "B streak" 1 (D.current_streak ~keeper_name:b);
  (* Resetting A's streak does not touch B. *)
  D.record_turn ~keeper_name:a ~speech_act:"declare";
  Alcotest.(check int) "A reset" 0 (D.current_streak ~keeper_name:a);
  Alcotest.(check int) "B unchanged" 1 (D.current_streak ~keeper_name:b)

let test_threshold_env_default_is_10 () =
  clear_threshold ();
  Alcotest.(check int) "default threshold" 10 (D.threshold ())

let test_threshold_env_custom () =
  set_threshold 25;
  Alcotest.(check int) "custom 25" 25 (D.threshold ());
  set_threshold 1;
  Alcotest.(check int) "custom 1" 1 (D.threshold ());
  clear_threshold ()

let test_threshold_env_invalid_falls_through_to_default () =
  Unix.putenv "MASC_STAY_SILENT_LOOP_THRESHOLD" "notanumber";
  Alcotest.(check int) "non-numeric → default" 10 (D.threshold ());
  Unix.putenv "MASC_STAY_SILENT_LOOP_THRESHOLD" "0";
  Alcotest.(check int) "0 → default (not useful)" 10 (D.threshold ());
  Unix.putenv "MASC_STAY_SILENT_LOOP_THRESHOLD" "-1";
  Alcotest.(check int) "-1 → default" 10 (D.threshold ());
  clear_threshold ()

let test_explicit_reset () =
  D.reset_all_for_test ();
  let k = "test-keeper-explicit-reset" in
  for _ = 1 to 5 do
    D.record_turn ~keeper_name:k ~speech_act:"stay_silent"
  done;
  Alcotest.(check int) "pre explicit reset" 5
    (D.current_streak ~keeper_name:k);
  D.reset ~keeper_name:k;
  Alcotest.(check int) "post explicit reset" 0
    (D.current_streak ~keeper_name:k)

let () =
  Alcotest.run "keeper_stay_silent_loop_detector"
    [
      ( "streak semantics",
        [
          Alcotest.test_case "increments on stay_silent"
            `Quick (with_eio test_streak_increments);
          Alcotest.test_case "any other act resets"
            `Quick (with_eio test_any_other_act_resets);
          Alcotest.test_case "explicit reset"
            `Quick (with_eio test_explicit_reset);
        ] );
      ( "threshold crossing",
        [
          Alcotest.test_case "fires counter at threshold"
            `Quick (with_eio test_threshold_crossing_fires_counter);
          Alcotest.test_case "latched: no repeat while streak grows"
            `Quick (with_eio test_latched_no_repeat_while_streak_grows);
          Alcotest.test_case "latch releases on reset, then re-fires"
            `Quick (with_eio test_latch_releases_on_reset_then_refires);
        ] );
      ( "per-keeper isolation",
        [
          Alcotest.test_case "A and B independent"
            `Quick (with_eio test_per_keeper_isolation);
        ] );
      ( "threshold env var",
        [
          Alcotest.test_case "default 10"
            `Quick (with_eio test_threshold_env_default_is_10);
          Alcotest.test_case "custom values"
            `Quick (with_eio test_threshold_env_custom);
          Alcotest.test_case "invalid falls to default"
            `Quick (with_eio test_threshold_env_invalid_falls_through_to_default);
        ] );
    ]
