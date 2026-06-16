(* test/test_no_progress_loop_detector.ml

   #9926: detector observability contract. Pins:
   - Streak increments on consecutive no-progress turns
   - Streak resets to 0 on any progress turn
   - Detected-counter only bumps once per loop episode (latched)
   - Reset latches on streak reset
   - Threshold is the product constant
   - Per-keeper isolation *)

module D = Masc.Keeper_no_progress_loop_detector
module Metrics = Masc.Otel_metric_store

(* Detector now uses Eio.Mutex (was Stdlib.Mutex; the latter raised EDEADLK
   under any fiber contention). Every public entry needs an Eio fiber
   context, so wrap each Alcotest body in Eio_main.run. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

let detected_count keeper =
  Metrics.metric_value_or_zero
    "masc_keeper_no_progress_loop_detected_total"
    ~labels:[ ("keeper", keeper) ] ()

let record_turn = D.record_turn

let ignore_outcome = function
  | D.Normal | D.Loop_detected _ | D.Loop_reset _ -> ()

let test_streak_increments () =
  D.reset_all_for_test ();
  let k = "test-keeper-increments" in
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "after 1" 1 (D.current_streak ~keeper_name:k);
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "after 3" 3 (D.current_streak ~keeper_name:k)

let test_any_other_act_resets () =
  D.reset_all_for_test ();
  let k = "test-keeper-resets" in
  for _ = 1 to 5 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check int) "pre-reset" 5 (D.current_streak ~keeper_name:k);
  (match record_turn ~keeper_name:k ~made_progress:true with
   | D.Loop_reset { previous_streak; was_latched } ->
     Alcotest.(check int) "reset previous streak" 5 previous_streak;
     Alcotest.(check bool) "reset was not latched" false was_latched
   | D.Normal | D.Loop_detected _ -> Alcotest.fail "expected loop reset");
  Alcotest.(check int) "after declare" 0 (D.current_streak ~keeper_name:k);
  record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "after new no-progress turn" 1
    (D.current_streak ~keeper_name:k)

let test_threshold_crossing_fires_counter () =
  D.reset_all_for_test ();
  let k = "test-keeper-threshold-fires" in
  let before = detected_count k in
  for _ = 1 to D.threshold () - 1 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "no fire before threshold" before
    (detected_count k);
  (match record_turn ~keeper_name:k ~made_progress:false with
   | D.Loop_detected { streak; threshold } ->
     Alcotest.(check int) "loop streak" threshold streak
   | D.Normal | D.Loop_reset _ -> Alcotest.fail "expected loop detection at threshold");
  Alcotest.(check (float 0.0001)) "fires at threshold"
    (before +. 1.0) (detected_count k);
  ()

let test_latched_no_repeat_while_streak_grows () =
  D.reset_all_for_test ();
  let k = "test-keeper-latched" in
  let before = detected_count k in
  for _ = 1 to D.threshold () + 7 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "latched: exactly +1 across long no-progress run"
    (before +. 1.0) (detected_count k)

let test_latch_releases_on_reset_then_refires () =
  D.reset_all_for_test ();
  let k = "test-keeper-relatch" in
  let before = detected_count k in
  for _ = 1 to D.threshold () + 2 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "first loop fires once"
    (before +. 1.0) (detected_count k);
  (* Break the loop with a progress turn. *)
  (match record_turn ~keeper_name:k ~made_progress:true with
   | D.Loop_reset { was_latched; _ } ->
     Alcotest.(check bool) "reset releases latched loop" true was_latched
   | D.Normal | D.Loop_detected _ -> Alcotest.fail "expected latched loop reset");
  (* Start a second loop. *)
  for _ = 1 to D.threshold () + 2 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check (float 0.0001)) "second loop fires once more"
    (before +. 2.0) (detected_count k)

let test_per_keeper_isolation () =
  D.reset_all_for_test ();
  let a = "test-keeper-A" in
  let b = "test-keeper-B" in
  for _ = 1 to 4 do
    record_turn ~keeper_name:a ~made_progress:false |> ignore_outcome
  done;
  record_turn ~keeper_name:b ~made_progress:false |> ignore_outcome;
  Alcotest.(check int) "A streak" 4 (D.current_streak ~keeper_name:a);
  Alcotest.(check int) "B streak" 1 (D.current_streak ~keeper_name:b);
  (* Resetting A's streak does not touch B. *)
  record_turn ~keeper_name:a ~made_progress:true |> ignore_outcome;
  Alcotest.(check int) "A reset" 0 (D.current_streak ~keeper_name:a);
  Alcotest.(check int) "B unchanged" 1 (D.current_streak ~keeper_name:b)

let test_threshold_constant_is_10 () =
  Alcotest.(check int) "default threshold" 10 (D.threshold ())

let test_threshold_env_is_ignored () =
  Unix.putenv "MASC_NO_PROGRESS_LOOP_THRESHOLD" "25";
  Alcotest.(check int) "env ignored" 10 (D.threshold ());
  Unix.putenv "MASC_NO_PROGRESS_LOOP_THRESHOLD" "notanumber";
  Alcotest.(check int) "non-numeric → default" 10 (D.threshold ());
  Unix.putenv "MASC_NO_PROGRESS_LOOP_THRESHOLD" ""

let test_explicit_reset () =
  D.reset_all_for_test ();
  let k = "test-keeper-explicit-reset" in
  for _ = 1 to 5 do
    record_turn ~keeper_name:k ~made_progress:false |> ignore_outcome
  done;
  Alcotest.(check int) "pre explicit reset" 5
    (D.current_streak ~keeper_name:k);
  D.reset ~keeper_name:k;
  Alcotest.(check int) "post explicit reset" 0
    (D.current_streak ~keeper_name:k)

(* RFC-0239 §3 R3: the no-progress predicate. A turn makes progress iff it
   produced durable evidence OR was on a surface that does not require it. The
   key new case is the third one: a no-evidence turn on a peer-facing surface
   (board post) is NOT progress, so the streak accrues — the exact case the old
   literal silent speech-act check missed. *)
let test_made_progress_predicate () =
  Alcotest.(check bool) "evidence on evidence-required surface = progress" true
    (D.turn_made_progress ~strong_evidence:true ~surface_requires_evidence:true);
  Alcotest.(check bool)
    "NO evidence on evidence-required surface (board post) = no progress" false
    (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence:true);
  Alcotest.(check bool) "no evidence on non-required surface (user reply) = progress"
    true
    (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence:false);
  Alcotest.(check bool) "evidence on non-required surface = progress" true
    (D.turn_made_progress ~strong_evidence:true ~surface_requires_evidence:false)

let test_no_progress_board_post_accrues_streak () =
  (* End-to-end of the R3 fix at the detector boundary: a keeper that posts to
     the board with no evidence (made_progress=false) must accrue the streak,
     where the old detector reset it. *)
  D.reset_all_for_test ();
  let k = "test-keeper-board-thrash" in
  for _ = 1 to 4 do
    record_turn
      ~keeper_name:k
      ~made_progress:
        (D.turn_made_progress ~strong_evidence:false ~surface_requires_evidence:true)
    |> ignore_outcome
  done;
  Alcotest.(check int) "board posts without evidence accrue streak" 4
    (D.current_streak ~keeper_name:k)

let () =
  Alcotest.run "keeper_no_progress_loop_detector"
    [
      ( "streak semantics",
        [
          Alcotest.test_case "increments on no-progress"
            `Quick (with_eio test_streak_increments);
          Alcotest.test_case "progress resets"
            `Quick (with_eio test_any_other_act_resets);
          Alcotest.test_case "explicit reset"
            `Quick (with_eio test_explicit_reset);
          Alcotest.test_case "no-progress predicate (RFC-0239 R3)"
            `Quick (with_eio test_made_progress_predicate);
          Alcotest.test_case "no-progress board post accrues streak (RFC-0239 R3)"
            `Quick (with_eio test_no_progress_board_post_accrues_streak);
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
      ( "threshold policy",
        [
          Alcotest.test_case "constant 10"
            `Quick (with_eio test_threshold_constant_is_10);
          Alcotest.test_case "env var ignored"
            `Quick (with_eio test_threshold_env_is_ignored);
        ] );
    ]
