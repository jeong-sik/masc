(* test/test_keeper_turn_livelock_10121.ml

   #10121 reports 10 (keeper, turn) pairs retrying 4-12× over
   4+ hours with no FSM guard.  This test pins the
   observability surface that surfaces those retries directly
   to Otel_metric_store instead of leaving them buried in log lines:

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

module L = Masc.Keeper_turn_livelock
module Metrics = Masc.Otel_metric_store
module KR = Masc.Keeper_registry
module KMC = Masc.Keeper_meta_contract

(* Keeper_turn_livelock state now lives in the keeper registry entry and is
   updated through the registry CAS loop. Tests therefore register a minimal
   keeper entry before exercising the public functions. *)
let base_path () = Sys.getenv "MASC_BASE_PATH"

let register_keeper keeper =
  let meta =
    match
      Masc_test_deps.meta_of_json_fixture
        (`Assoc [ ("name", `String keeper); ("agent_name", `String keeper) ])
    with
    | Ok meta -> meta
    | Error e -> failwith (Printf.sprintf "register_keeper %s: %s" keeper e)
  in
  ignore (KR.register ~base_path:(base_path ()) keeper meta : KR.registry_entry)

(* Keeper_turn_livelock public entry points need an Eio fiber context, so
   wrap each Alcotest test body in Eio_main.run. *)
let with_eio f () = Eio_main.run @@ fun _env -> f ()

let starts_for ~keeper =
  Metrics.metric_value_or_zero Keeper_metrics.(to_string TurnStarts)
    ~labels:[ ("keeper", keeper) ] ()

let scheduled_for ~keeper =
  Metrics.metric_value_or_zero Keeper_metrics.(to_string TurnScheduled)
    ~labels:[ ("keeper", keeper) ] ()

let reattempts_for ~keeper =
  Metrics.metric_value_or_zero Keeper_metrics.(to_string TurnReattempts)
    ~labels:[ ("keeper", keeper) ] ()

let regressions_for ~keeper =
  Metrics.metric_value_or_zero Keeper_metrics.(to_string TurnRegressions)
    ~labels:[ ("keeper", keeper) ] ()

let blocks_for ~keeper ~reason =
  Metrics.metric_value_or_zero Keeper_metrics.(to_string TurnLivelockBlocks)
    ~labels:[ ("keeper", keeper); ("reason", reason) ] ()

(* Fresh start: no prior state → [Fresh] outcome, starts counter
   +1, reattempt counter unchanged. *)
let test_fresh_first_start () =
  L.reset_for_tests ();
  let keeper = "test-keeper-fresh-10121" in
  register_keeper keeper;
  let base = base_path () in
  let before_starts = starts_for ~keeper in
  let before_scheduled = scheduled_for ~keeper in
  let before_reattempts = reattempts_for ~keeper in
  let outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:1 in
  Alcotest.(check bool) "outcome is Fresh" true (outcome = L.Fresh);
  Alcotest.(check (float 0.0001))
    "starts +1"
    (before_starts +. 1.0) (starts_for ~keeper);
  Alcotest.(check (float 0.0001))
    "scheduled +1"
    (before_scheduled +. 1.0) (scheduled_for ~keeper);
  Alcotest.(check (float 0.0001))
    "reattempts unchanged"
    before_reattempts (reattempts_for ~keeper)

(* Same turn id starts twice → second is Reattempt, counter
   labelled correctly. *)
let test_same_turn_classifies_as_reattempt () =
  L.reset_for_tests ();
  let keeper = "test-keeper-reattempt-10121" in
  register_keeper keeper;
  let base = base_path () in
  let before_reattempts = reattempts_for ~keeper in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:91 in
  let outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:91 in
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
  register_keeper keeper;
  let base = base_path () in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:91 in
  let counts = List.init 11 (fun _ ->
    match L.record_turn_start ~base_path:base ~keeper ~turn_id:91 with
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
  register_keeper keeper;
  let base = base_path () in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:5 in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:5 in
  let before_reattempts = reattempts_for ~keeper in
  let outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:6 in
  Alcotest.(check bool) "advance is Fresh" true (outcome = L.Fresh);
  Alcotest.(check (float 0.0001))
    "advance does not increment reattempts"
    before_reattempts (reattempts_for ~keeper);
  (* And the next start at the new id classifies as Reattempt
     against the NEW id, not the old one. *)
  let outcome2 = L.record_turn_start ~base_path:base ~keeper ~turn_id:6 in
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
  register_keeper keeper;
  let base = base_path () in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:91 in
  let before_regressions = regressions_for ~keeper in
  let outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:90 in
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
  register_keeper a;
  register_keeper b;
  let base = base_path () in
  let before_b = reattempts_for ~keeper:b in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper:a ~turn_id:1 in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper:a ~turn_id:1 in
  Alcotest.(check (float 0.0001))
    "keeper B unaffected by keeper A reattempts"
    before_b (reattempts_for ~keeper:b)

(* seconds_since_first_attempt accuracy.  After two reattempts
   with a small sleep between them, the wrapper should report
   roughly the elapsed time since the FIRST attempt. *)
let test_seconds_since_first_attempt () =
  L.reset_for_tests ();
  let keeper = "test-keeper-stuck-time-10121" in
  register_keeper keeper;
  let base = base_path () in
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:1 in
  Unix.sleepf 0.05;
  let _ : L.start_outcome = L.record_turn_start ~base_path:base ~keeper ~turn_id:1 in
  match L.seconds_since_first_attempt ~base_path:base ~keeper with
  | None -> Alcotest.fail "expected Some elapsed seconds"
  | Some t ->
    Alcotest.(check bool)
      "elapsed >= 50ms (sleep) and < 60s (test budget)"
      true (t >= 0.04 && t < 60.0)

let test_guard_blocks_after_max_attempts () =
  L.reset_for_tests ();
  let keeper = "test-keeper-guard-max-10121" in
  register_keeper keeper;
  let base = base_path () in
  let now = ref 1000.0 in
  let call () =
    L.guard_and_record_turn_start
      ~now:(fun () -> !now)
      ~base_path:base
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
  register_keeper keeper;
  let base = base_path () in
  let now = ref 10.0 in
  let call () =
    L.guard_and_record_turn_start
      ~now:(fun () -> !now)
      ~base_path:base
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
  register_keeper keeper;
  let base = base_path () in
  let call turn_id =
    L.guard_and_record_turn_start
      ~now:(fun () -> 100.0)
      ~base_path:base
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

(* F2: a legacy provider_timeout terminal resets the livelock entry via
   [reset_keeper_livelock] before the same
   turn_id is re-dispatched (see keeper_unified_turn_types.ml,
   legacy "attempt_watchdog_safety_deadline" arm). Pin the invariant that wiring
   relies on: a re-dispatch whose age would otherwise cross
   [stuck_after_sec] is reclassified [Fresh] once the entry is reset, so a
   transport stall routes to autonomous retry instead of
   [Stuck_age_exceeded] -> operator_pause. Mirror of
   [test_guard_blocks_on_stuck_age] with the reset interposed. *)
let test_reset_clears_stuck_age_for_provider_timeout () =
  L.reset_for_tests ();
  let keeper = "test-keeper-reset-stuck-age-10121" in
  register_keeper keeper;
  let base = base_path () in
  let now = ref 10.0 in
  let call () =
    L.guard_and_record_turn_start
      ~now:(fun () -> !now)
      ~base_path:base
      ~keeper
      ~turn_id:24
      ~max_attempts:10
      ~stuck_after_sec:30.0
      ()
  in
  (match call () with
   | L.Started L.Fresh -> ()
   | _ -> Alcotest.fail "first attempt should start fresh");
  (* Age now far exceeds the threshold; without the reset this is the exact
     scenario [test_guard_blocks_on_stuck_age] proves blocks. *)
  now := 1810.0;
  L.reset_keeper_livelock ~base_path:base ~keeper;
  (match call () with
   | L.Started L.Fresh -> ()
   | L.Blocked (L.Stuck_age_exceeded _) ->
     Alcotest.fail
       "after reset_keeper_livelock the same turn_id must not trip stuck-age"
   | _ -> Alcotest.fail "after reset the same turn_id should start Fresh");
  Alcotest.(check (float 0.0001))
    "no stuck-age block recorded for this keeper after reset"
    0.0
    (blocks_for ~keeper ~reason:"stuck_age_exceeded")

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
          Alcotest.test_case "reset clears stuck-age (provider_timeout)" `Quick
            (with_eio test_reset_clears_stuck_age_for_provider_timeout);
        ] );
    ]
