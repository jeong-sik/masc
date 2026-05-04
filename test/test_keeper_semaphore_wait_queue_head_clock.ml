(** Regression: queue-head wait timeout clock must be reset after the keeper
    joins the FIFO, not inherited from slot-entry.

    Production symptom (live log 2026-05-05 ~01:50 KST, masc-mcp):

      [WARN] [Keeper] <name>: skipping turn (semaphore wait > 60s,
        peers holding slot, cascade=..., autonomous_available=6
        turn_available=12)

    fired across 14 keepers simultaneously while
    [autonomous_turn_semaphore] reported 6 free slots — i.e. capacity was
    available, but every waiter timed out before reaching head-of-queue.

    Root cause: [with_keeper_turn_slot] captured [t0] BEFORE
    [maybe_yield_for_fairness], then passed that same [t0] to
    [wait_for_autonomous_queue_head] as [~started_at]. Any time spent in
    the fairness cooldown was silently subtracted from the
    [semaphore_wait_timeout_sec] budget for the queue-head phase. With
    cooldown ≈ 5s, every keeper had only 55s to reach head; chains of
    slow LLM turns at the head of the queue then trip the timeout for
    the entire tail.

    Fix: [with_keeper_turn_slot] now captures a fresh [queue_entered_at]
    after [enqueue_autonomous_waiter] and passes that to
    [wait_for_autonomous_queue_head].

    These tests exercise the parameter directly via
    [wait_for_autonomous_queue_head_for_test]: they prove the function's
    timeout decision is anchored on [~started_at], so passing a stale
    timestamp causes immediate [Semaphore_wait_timeout]. The fix at
    [with_keeper_turn_slot] removes the only path that produced a stale
    [~started_at] in production. *)

open Masc_mcp

let timeout_sec = Keeper_turn_slot.semaphore_wait_timeout_sec

let test_stale_started_at_times_out_immediately () =
  Eio_main.run @@ fun _env ->
  Keeper_turn_slot.reset_autonomous_turn_queue_for_test ();
  let blocker = Keeper_turn_slot.enqueue_autonomous_waiter_for_test "blocker" in
  let ours = Keeper_turn_slot.enqueue_autonomous_waiter_for_test "ours" in
  Fun.protect
    ~finally:(fun () ->
      Keeper_turn_slot.drop_autonomous_waiter_for_test ours;
      Keeper_turn_slot.drop_autonomous_waiter_for_test blocker)
    (fun () ->
      let stale_started_at = Unix.gettimeofday () -. (timeout_sec +. 5.0) in
      match
        Keeper_turn_slot.wait_for_autonomous_queue_head_for_test
          ~keeper_name:"ours"
          ~ticket:ours
          ~started_at:stale_started_at
      with
      | Error (`Semaphore_wait_timeout waited) ->
        Alcotest.(check (float 0.001))
          "timeout value is the configured cap"
          timeout_sec
          waited
      | Ok () ->
        Alcotest.fail
          "expected Semaphore_wait_timeout from a stale [started_at] but got Ok"
      | Error _ ->
        Alcotest.fail "expected Semaphore_wait_timeout variant")

let test_fresh_started_at_at_head_returns_ok () =
  Eio_main.run @@ fun _env ->
  Keeper_turn_slot.reset_autonomous_turn_queue_for_test ();
  let ours = Keeper_turn_slot.enqueue_autonomous_waiter_for_test "ours" in
  Fun.protect
    ~finally:(fun () -> Keeper_turn_slot.drop_autonomous_waiter_for_test ours)
    (fun () ->
      let fresh = Unix.gettimeofday () in
      match
        Keeper_turn_slot.wait_for_autonomous_queue_head_for_test
          ~keeper_name:"ours"
          ~ticket:ours
          ~started_at:fresh
      with
      | Ok () ->
        Alcotest.(check pass)
          "head waiter with fresh clock returns Ok immediately"
          ()
          ()
      | Error _ ->
        Alcotest.fail
          "expected Ok when this is the only waiter and clock is fresh")

let () =
  Alcotest.run
    "keeper_semaphore_wait_queue_head_clock"
    [ ( "queue_head_clock_freshness"
      , [ Alcotest.test_case
            "stale started_at causes immediate timeout (proves parameter is the knob)"
            `Quick
            test_stale_started_at_times_out_immediately
        ; Alcotest.test_case
            "fresh started_at at head returns Ok"
            `Quick
            test_fresh_started_at_at_head_returns_ok
        ] )
    ]
;;
