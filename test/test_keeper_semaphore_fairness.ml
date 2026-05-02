(** Regression tests for autonomous semaphore fairness cooldown (#6810).

    Background: janitor completed 9 consecutive ~20s turns while
    cheolsu/sangsu/masc-improver/uranium666 all hit the 60s autonomous
    semaphore wait timeout.  The queue is FIFO-fair in isolation, but a
    fast-cycling keeper that re-enters the queue immediately after
    releasing the semaphore outruns peers whose heartbeat intervals are
    longer.

    Fix: [maybe_yield_for_fairness] stamps each autonomous-turn
    completion, then checks before re-enqueueing: if other keepers are
    waiting AND this keeper completed within [autonomous_fairness_cooldown_sec]
    seconds ago, it yields for the remaining cooldown window.

    These tests exercise [fairness_delay_sec_at] — the pure delay-
    computation extracted from [maybe_yield_for_fairness] — so we never
    need to actually sleep in a test. *)

module KK = Masc_mcp.Keeper_keepalive

(** Reset both the completion table and the FIFO wait queue between tests.

    Keeper_keepalive now uses Eio.Mutex (was Stdlib.Mutex; the latter
    raised EDEADLK under any fiber contention). All public entries
    require an Eio fiber context, so each test runs inside Eio_main.run.
    Tests that need [env] or [sw] take the unit-arg form and fetch them
    via [Eio.Stdenv.*] inside [body_with_env]. *)
let with_fresh_state test_body () =
  Eio_main.run @@ fun _env ->
    KK.reset_autonomous_completion_for_test ();
    KK.reset_autonomous_turn_queue_for_test ();
    test_body ()

(** Variant for tests that need [env] (clock, sw). *)
let with_fresh_state_env test_body () =
  Eio_main.run @@ fun env ->
    KK.reset_autonomous_completion_for_test ();
    KK.reset_autonomous_turn_queue_for_test ();
    test_body env

(* --------------------------------------------------------------------------
   fairness_delay_sec_at: core logic
   -------------------------------------------------------------------------- *)

let test_no_completion_no_delay () =
  (* Keeper has never completed an autonomous turn: no stamp → no delay. *)
  let delay = KK.fairness_delay_sec_at ~now:1_000_000.0 ~keeper_name:"janitor" in
  Alcotest.(check (float 0.001)) "no completion → 0.0 delay" 0.0 delay

let test_no_others_waiting_no_delay () =
  (* No peers in queue: even if cooldown would fire, skip it. *)
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:1_000_000.0;
  (* janitor is NOT in the queue here; nothing else is either. *)
  let delay =
    KK.fairness_delay_sec_at ~now:1_000_000.5 ~keeper_name:"janitor"
  in
  Alcotest.(check (float 0.001)) "no queue waiters → 0.0 delay" 0.0 delay

let test_others_waiting_fresh_completion_delays () =
  (* janitor completed 0.5s ago; peer is waiting; 5s cooldown → ~4.5s remain. *)
  let t_done = 1_000_000.0 in
  let now = t_done +. 0.5 in
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:t_done;
  (* Enqueue a peer so [others_waiting_in_queue] returns true. *)
  let ticket = KK.enqueue_autonomous_waiter_for_test "cheolsu" in
  let delay = KK.fairness_delay_sec_at ~now ~keeper_name:"janitor" in
  KK.drop_autonomous_waiter_for_test ticket;
  (* Default cooldown is 5s; elapsed 0.5s → remaining ≈ 4.5s.
     We test with an approximate tolerance. *)
  Alcotest.(check bool) "delay > 4.0s" true (delay > 4.0);
  Alcotest.(check bool) "delay <= 5.0s" true (delay <= 5.0)

let test_others_waiting_cooldown_expired_no_delay () =
  (* Cooldown window already elapsed (6s ago at 5s cooldown). *)
  let t_done = 1_000_000.0 in
  let now = t_done +. 6.0 in
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:t_done;
  let ticket = KK.enqueue_autonomous_waiter_for_test "sangsu" in
  let delay = KK.fairness_delay_sec_at ~now ~keeper_name:"janitor" in
  KK.drop_autonomous_waiter_for_test ticket;
  Alcotest.(check (float 0.001)) "expired cooldown → 0.0 delay" 0.0 delay

let test_others_waiting_exactly_at_boundary_no_delay () =
  (* Completed exactly cooldown_sec ago → remaining = 0.0. *)
  let cooldown = 5.0 in
  let t_done = 1_000_000.0 in
  let now = t_done +. cooldown in
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:t_done;
  let ticket = KK.enqueue_autonomous_waiter_for_test "uranium666" in
  let delay = KK.fairness_delay_sec_at ~now ~keeper_name:"janitor" in
  KK.drop_autonomous_waiter_for_test ticket;
  Alcotest.(check (float 0.001)) "exactly at boundary → 0.0" 0.0 delay

let test_per_keeper_isolation () =
  (* Completing for 'janitor' must not affect 'cheolsu'. *)
  let t_done = 1_000_000.0 in
  let now = t_done +. 0.5 in
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:t_done;
  let ticket = KK.enqueue_autonomous_waiter_for_test "masc-improver" in
  let delay_cheolsu = KK.fairness_delay_sec_at ~now ~keeper_name:"cheolsu" in
  KK.drop_autonomous_waiter_for_test ticket;
  (* cheolsu has no completion stamp → no delay. *)
  Alcotest.(check (float 0.001)) "unrelated keeper unaffected" 0.0 delay_cheolsu

let test_reset_clears_completion_table () =
  (* After reset, a previously-stamped keeper sees no delay. *)
  let t_done = 1_000_000.0 in
  let now = t_done +. 0.5 in
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:t_done;
  KK.reset_autonomous_completion_for_test ();
  let ticket = KK.enqueue_autonomous_waiter_for_test "cheolsu" in
  let delay = KK.fairness_delay_sec_at ~now ~keeper_name:"janitor" in
  KK.drop_autonomous_waiter_for_test ticket;
  Alcotest.(check (float 0.001)) "reset clears stamps → 0.0" 0.0 delay

let test_delay_decreases_with_elapsed_time () =
  (* delay at t+1s > delay at t+3s. *)
  let t_done = 1_000_000.0 in
  KK.record_autonomous_completion_at_for_test ~keeper_name:"janitor" ~ts:t_done;
  let ticket = KK.enqueue_autonomous_waiter_for_test "sangsu" in
  let delay_1s = KK.fairness_delay_sec_at ~now:(t_done +. 1.0) ~keeper_name:"janitor" in
  let delay_3s = KK.fairness_delay_sec_at ~now:(t_done +. 3.0) ~keeper_name:"janitor" in
  KK.drop_autonomous_waiter_for_test ticket;
  Alcotest.(check bool) "delay decreases over time" true (delay_1s > delay_3s)

let test_reactive_slot_released_when_body_raises () =
  let before = KK.turn_semaphore_value_for_test () in
  let before_reactive = KK.reactive_turn_semaphore_value_for_test () in
  let completed =
    try
      Some
        (KK.with_keeper_turn_slot_for_test ~keeper_name:"reactive-test"
           ~channel:Masc_mcp.Keeper_world_observation.Reactive
           (fun ~semaphore_wait_ms:_ -> raise Exit))
    with Exit -> None
  in
  Alcotest.(check bool) "body exception propagated" true
    (Option.is_none completed);
  Alcotest.(check int) "turn semaphore restored" before
    (KK.turn_semaphore_value_for_test ());
  Alcotest.(check int) "reactive semaphore restored" before_reactive
    (KK.reactive_turn_semaphore_value_for_test ())

let test_autonomous_slot_released_when_body_raises () =
  let before_turn = KK.turn_semaphore_value_for_test () in
  let before_autonomous = KK.autonomous_turn_semaphore_value_for_test () in
  let completed =
    try
      Some
        (KK.with_keeper_turn_slot_for_test ~keeper_name:"autonomous-test"
           ~channel:Masc_mcp.Keeper_world_observation.Scheduled_autonomous
           (fun ~semaphore_wait_ms:_ -> raise Exit))
    with Exit -> None
  in
  Alcotest.(check bool) "body exception propagated" true
    (Option.is_none completed);
  Alcotest.(check int) "turn semaphore restored" before_turn
    (KK.turn_semaphore_value_for_test ());
  Alcotest.(check int) "autonomous semaphore restored" before_autonomous
    (KK.autonomous_turn_semaphore_value_for_test ());
  Alcotest.(check (list string)) "autonomous queue drained" []
    (KK.autonomous_waiter_snapshot_for_test ())

let test_in_turn_liveness_pulse_stops_when_body_raises env =
  Eio.Switch.run @@ fun sw ->
  let clock = Eio.Stdenv.clock env in
  let ticks = Atomic.make 0 in
  let raised =
    try
      let _ =
        KK.with_in_turn_liveness_pulse_for_test
          ~sw
          ~clock
          ~interval_sec:0.01
          ~tick:(fun () -> ignore (Atomic.fetch_and_add ticks 1))
          (fun () ->
            Eio.Time.sleep clock 0.025;
            raise Exit)
      in
      false
    with Exit -> true
  in
  Alcotest.(check bool) "body exception propagated" true raised;
  Alcotest.(check bool) "pulse ticked while body ran" true (Atomic.get ticks > 0);
  let ticks_after_raise = Atomic.get ticks in
  Eio.Time.sleep clock 0.04;
  Alcotest.(check int) "pulse stopped after body raised" ticks_after_raise
    (Atomic.get ticks)

let () =
  Alcotest.run "Keeper_semaphore_fairness"
    [
      ( "fairness_delay_sec_at",
        [
          Alcotest.test_case "no completion → no delay" `Quick
            (with_fresh_state test_no_completion_no_delay);
          Alcotest.test_case "no others waiting → no delay" `Quick
            (with_fresh_state test_no_others_waiting_no_delay);
          Alcotest.test_case "others waiting, fresh completion → delay" `Quick
            (with_fresh_state test_others_waiting_fresh_completion_delays);
          Alcotest.test_case "cooldown expired → no delay" `Quick
            (with_fresh_state test_others_waiting_cooldown_expired_no_delay);
          Alcotest.test_case "exactly at cooldown boundary → no delay" `Quick
            (with_fresh_state test_others_waiting_exactly_at_boundary_no_delay);
          Alcotest.test_case "per-keeper isolation" `Quick
            (with_fresh_state test_per_keeper_isolation);
          Alcotest.test_case "reset clears table" `Quick
            (with_fresh_state test_reset_clears_completion_table);
          Alcotest.test_case "delay decreases with elapsed time" `Quick
            (with_fresh_state test_delay_decreases_with_elapsed_time);
        ] );
      ( "slot_release",
        [
          Alcotest.test_case "reactive slot released when body raises" `Quick
            (with_fresh_state test_reactive_slot_released_when_body_raises);
          Alcotest.test_case "autonomous slot released when body raises" `Quick
            (with_fresh_state test_autonomous_slot_released_when_body_raises);
        ] );
      ( "in_turn_liveness",
        [
          Alcotest.test_case "pulse stops when body raises" `Quick
            (with_fresh_state_env test_in_turn_liveness_pulse_stops_when_body_raises);
        ] );
    ]
