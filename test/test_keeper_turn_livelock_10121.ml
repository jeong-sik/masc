(* test/test_keeper_turn_livelock_10121.ml

   #10121 reports 10 (keeper, turn) pairs retrying 4-12× over
   4+ hours with no FSM guard.  This test pins the
   observability surface that surfaces those retries directly
   to Prometheus instead of leaving them buried in log lines:

     1. The first start of any (keeper, turn_id) is [Fresh] —
        no reattempt counter increment.
     2. The same id starting again classifies as [Reattempt]
        and increments [masc_keeper_turn_reattempts_total].
        [previous_attempts] grows by 1 per reattempt.
     3. Advancing the turn id resets bookkeeping — a normal
        forward progression must NOT count as reattempt.
     4. A turn id moving strictly backwards classifies as
        [Regression] (write_meta race symptom #9733) and
        increments the regression counter.
     5. Per-keeper isolation: keeper A's reattempts do not
        leak into keeper B's counters even with identical
        turn ids.
     6. [seconds_since_first_attempt] returns the time since
        the FIRST start of the current turn id (so a future
        gate can compute "stuck for X minutes" without
        re-deriving the timeline).
     7. The guard blocks attempt 4 when [max_attempts=3],
        gates on stuck age, and resets on forward turn advance.
*)

let () =
  let dir =
    Filename.concat (Filename.get_temp_dir_name ())
      (Printf.sprintf "masc-test-keeper-turn-livelock-10121-%06x"
         (Random.bits ()))
  in
  Unix.putenv "MASC_BASE_PATH" dir

module L = Masc_mcp.Keeper_turn_livelock
module Prom = Masc_mcp.Prometheus

(* Keeper_turn_livelock now uses Eio.Mutex (was Stdlib.Mutex; the latter
   raised EDEADLK whenever two Eio fibers contended). Every public entry
   needs an Eio fiber context, so wrap each Alcotest test body in
   Eio_main.run. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

let starts_for ~keeper =
  Prom.metric_value_or_zero Prom.metric_keeper_turn_starts
    ~labels:[ ("keeper", keeper) ] ()

let reattempts_for ~keeper =
  Prom.metric_value_or_zero Prom.metric_keeper_turn_reattempts
    ~labels:[ ("keeper", keeper) ] ()

let regressions_for ~keeper =
  Prom.metric_value_or_zero Prom.metric_keeper_turn_regressions
    ~labels:[ ("keeper", keeper) ] ()

let blocks_for ~keeper ~reason =
  Prom.metric_value_or_zero Prom.metric_keeper_turn_livelock_blocks
    ~labels:[ ("keeper", keeper); ("reason", reason) ] ()

(* Fresh start: no prior state → [Fresh] outcome, starts counter
   +1, reattempt counter unchanged. *)
let test_fresh_first_start () =
  L.reset_for_tests ();
  let keeper = "test-keeper-fresh-10121" in
  let before_starts = starts_for ~keeper in
  let before_reattempts = reattempts_for ~keeper in
  let outcome = L.record_turn_start ~keeper ~turn_id:1 in
  Alcotest.(check bool) "outcome is Fresh" true (outcome = L.Fresh);
  Alcotest.(check (float 0.0001))
    "starts +1"
    (before_starts +. 1.0) (starts_for ~keeper);
  Alcotest.(check (float 0.0001))
    "reattempts unchanged"
    before_reattempts (reattempts_for ~keeper)

(* Same turn id starts twice → second is Reattempt, counter
   labelled correctly. *)
let test_same_turn_classifies_as_reattempt () =
  L.reset_for_tests ();
  let keeper = "test-keeper-reattempt-10121" in
  let before_reattempts = reattempts_for ~keeper in
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:91 in
  let outcome = L.record_turn_start ~keeper ~turn_id:91 in
  (match outcome with
   | L.Reattempt { previous_attempts; _ } ->
     Alcotest.(check int) "previous_attempts is 1" 1 previous_attempts
   | _ -> Alcotest.fail "expected Reattempt outcome");
  Alcotest.(check (float 0.0001))
    "reattempts +1"
    (before_reattempts +. 1.0) (reattempts_for ~keeper)

(* Multiple reattempts grow the previous_attempts count.  The
   #10121 worst case is 12× — pin that the count grows
   monotonically over many retries. *)
let test_reattempt_count_grows_monotonically () =
  L.reset_for_tests ();
  let keeper = "test-keeper-12x-10121" in
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:91 in
  let counts = List.init 11 (fun _ ->
    match L.record_turn_start ~keeper ~turn_id:91 with
    | L.Reattempt { previous_attempts; _ } -> previous_attempts
    | _ -> -1
  ) in
  Alcotest.(check (list int))
    "previous_attempts: 1, 2, 3, ..., 11"
    [1; 2; 3; 4; 5; 6; 7; 8; 9; 10; 11]
    counts

(* Forward progression: turn id advances → outcome is Fresh,
   no reattempt counter increment. *)
let test_forward_advance_resets () =
  L.reset_for_tests ();
  let keeper = "test-keeper-advance-10121" in
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:5 in
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:5 in
  let before_reattempts = reattempts_for ~keeper in
  let outcome = L.record_turn_start ~keeper ~turn_id:6 in
  Alcotest.(check bool) "advance is Fresh" true (outcome = L.Fresh);
  Alcotest.(check (float 0.0001))
    "advance does not increment reattempts"
    before_reattempts (reattempts_for ~keeper);
  (* And the next start at the new id classifies as Reattempt
     against the NEW id, not the old one. *)
  let outcome2 = L.record_turn_start ~keeper ~turn_id:6 in
  match outcome2 with
  | L.Reattempt { previous_attempts; _ } ->
    Alcotest.(check int)
      "reattempt of new id starts at previous_attempts=1"
      1 previous_attempts
  | _ -> Alcotest.fail "expected Reattempt of new id"

(* Backwards regression: write_meta race symptom from #9733. *)
let test_backward_turn_classifies_as_regression () =
  L.reset_for_tests ();
  let keeper = "test-keeper-regression-10121" in
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:91 in
  let before_regressions = regressions_for ~keeper in
  let outcome = L.record_turn_start ~keeper ~turn_id:90 in
  (match outcome with
   | L.Regression { previous_turn_id } ->
     Alcotest.(check int) "previous_turn_id is 91" 91 previous_turn_id
   | _ -> Alcotest.fail "expected Regression outcome");
  Alcotest.(check (float 0.0001))
    "regressions +1"
    (before_regressions +. 1.0) (regressions_for ~keeper)

(* Per-keeper isolation. *)
let test_keeper_isolation () =
  L.reset_for_tests ();
  let a = "test-keeper-iso-A-10121" in
  let b = "test-keeper-iso-B-10121" in
  let before_b = reattempts_for ~keeper:b in
  let _ : L.start_outcome = L.record_turn_start ~keeper:a ~turn_id:1 in
  let _ : L.start_outcome = L.record_turn_start ~keeper:a ~turn_id:1 in
  Alcotest.(check (float 0.0001))
    "keeper B unaffected by keeper A reattempts"
    before_b (reattempts_for ~keeper:b)

(* seconds_since_first_attempt accuracy.  After two reattempts
   with a small sleep between them, the wrapper should report
   roughly the elapsed time since the FIRST attempt. *)
let test_seconds_since_first_attempt () =
  L.reset_for_tests ();
  let keeper = "test-keeper-stuck-time-10121" in
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:1 in
  Unix.sleepf 0.05;
  let _ : L.start_outcome = L.record_turn_start ~keeper ~turn_id:1 in
  match L.seconds_since_first_attempt ~keeper with
  | None -> Alcotest.fail "expected Some elapsed seconds"
  | Some t ->
    Alcotest.(check bool)
      "elapsed >= 50ms (sleep) and < 60s (test budget)"
      true (t >= 0.04 && t < 60.0)

let test_guard_blocks_after_max_attempts () =
  L.reset_for_tests ();
  let keeper = "test-keeper-guard-max-10121" in
  let now = ref 1000.0 in
  let call () =
    L.guard_and_record_turn_start
      ~now:(fun () -> !now)
      ~keeper
      ~turn_id:91
      ~max_attempts:3
      ~stuck_after_sec:3600.0
      ()
  in
  let before_starts = starts_for ~keeper in
  let before_blocks =
    blocks_for ~keeper ~reason:"attempts_exhausted"
  in
  (match call () with
   | L.Started L.Fresh -> ()
   | _ -> Alcotest.fail "attempt 1 should start fresh");
  (match call () with
   | L.Started (L.Reattempt { previous_attempts = 1; _ }) -> ()
   | _ -> Alcotest.fail "attempt 2 should start");
  (match call () with
   | L.Started (L.Reattempt { previous_attempts = 2; _ }) -> ()
   | _ -> Alcotest.fail "attempt 3 should start");
  (match call () with
   | L.Blocked (L.Attempts_exhausted { attempts; max_attempts; _ }) ->
     Alcotest.(check int) "attempts held at 3" 3 attempts;
     Alcotest.(check int) "max attempts" 3 max_attempts
   | _ -> Alcotest.fail "attempt 4 should be blocked");
  Alcotest.(check (float 0.0001))
    "only the three dispatches increment starts"
    (before_starts +. 3.0) (starts_for ~keeper);
  Alcotest.(check (float 0.0001))
    "block counter +1"
    (before_blocks +. 1.0)
    (blocks_for ~keeper ~reason:"attempts_exhausted")

let test_guard_blocks_on_stuck_age () =
  L.reset_for_tests ();
  let keeper = "test-keeper-guard-age-10121" in
  let now = ref 10.0 in
  let call () =
    L.guard_and_record_turn_start
      ~now:(fun () -> !now)
      ~keeper
      ~turn_id:24
      ~max_attempts:10
      ~stuck_after_sec:30.0
      ()
  in
  (match call () with
   | L.Started L.Fresh -> ()
   | _ -> Alcotest.fail "first attempt should start");
  now := 41.0;
  (match call () with
   | L.Blocked
       (L.Stuck_age_exceeded { attempts; age_sec; threshold_sec; _ }) ->
     Alcotest.(check int) "only one prior attempt" 1 attempts;
     Alcotest.(check bool) "age crosses threshold" true (age_sec >= 30.0);
     Alcotest.(check (float 0.0001)) "threshold" 30.0 threshold_sec
   | _ -> Alcotest.fail "stuck age should block");
  Alcotest.(check (float 0.0001))
    "age block counter +1"
    1.0 (blocks_for ~keeper ~reason:"stuck_age_exceeded")

let test_guard_forward_advance_resets () =
  L.reset_for_tests ();
  let keeper = "test-keeper-guard-advance-10121" in
  let call turn_id =
    L.guard_and_record_turn_start
      ~now:(fun () -> 100.0)
      ~keeper
      ~turn_id
      ~max_attempts:2
      ~stuck_after_sec:3600.0
      ()
  in
  ignore (call 7 : L.guarded_start_outcome);
  ignore (call 7 : L.guarded_start_outcome);
  (match call 7 with
   | L.Blocked (L.Attempts_exhausted _) -> ()
   | _ -> Alcotest.fail "third attempt for turn 7 should block");
  (match call 8 with
   | L.Started L.Fresh -> ()
   | _ -> Alcotest.fail "turn 8 should reset guard state")

let () =
  Alcotest.run "keeper_turn_livelock_10121"
    [
      ( "fresh",
        [
          Alcotest.test_case "first start is Fresh" `Quick
            (with_eio test_fresh_first_start);
        ] );
      ( "reattempt",
        [
          Alcotest.test_case "same id is Reattempt" `Quick
            (with_eio test_same_turn_classifies_as_reattempt);
          Alcotest.test_case "reattempt count grows" `Quick
            (with_eio test_reattempt_count_grows_monotonically);
          Alcotest.test_case "forward advance resets" `Quick
            (with_eio test_forward_advance_resets);
        ] );
      ( "regression",
        [
          Alcotest.test_case "backward id is Regression" `Quick
            (with_eio test_backward_turn_classifies_as_regression);
        ] );
      ( "isolation",
        [
          Alcotest.test_case "per-keeper labels" `Quick
            (with_eio test_keeper_isolation);
        ] );
      ( "timing",
        [
          Alcotest.test_case "seconds_since_first_attempt" `Quick
            (with_eio test_seconds_since_first_attempt);
        ] );
      ( "guard",
        [
          Alcotest.test_case "max attempts gates attempt 4" `Quick
            (with_eio test_guard_blocks_after_max_attempts);
          Alcotest.test_case "stuck age gates dispatch" `Quick
            (with_eio test_guard_blocks_on_stuck_age);
          Alcotest.test_case "forward advance resets guard" `Quick
            (with_eio test_guard_forward_advance_resets);
        ] );
    ]
