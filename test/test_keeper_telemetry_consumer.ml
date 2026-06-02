(** Cooperative-scheduling regression test for [Keeper_telemetry_consumer].

    The drain fiber forked by [spawn_subscriber] consumes a non-blocking
    primitive ([Agent_sdk_metrics_bridge.drain]). Without an explicit
    yield it pins its Eio domain at ~100% CPU and starves every
    co-located fiber on the same domain — including timer fibers, so a
    [Eio.Time.sleep] in a sibling fiber never fires.

    This test runs [spawn_subscriber] under a switch and then asks the
    main fiber to perform a short sleep loop. If the drain fiber yields
    (the contract from RFC-0063 §6, encoded by PR #14499 as
    [Eio.Time.sleep clock drain_interval_s]), the main fiber's sleeps
    fire and the counter reaches its target. If a future change drops
    the yield, the main fiber's first sleep never wakes up and the test
    hangs — the CI wall-clock cutoff catches it.

    Regression context: PR #14491 introduced [spawn_subscriber] without
    a yield; PR #14499 restored cooperative behaviour; RFC-0063 §7-D
    classifies this style of harness as "partial coverage, low cost". *)

module KTC = Masc_mcp.Keeper_telemetry_consumer

let target_iters = 5
let inter_sleep_s = 0.02
let total_expected_wall_clock_s = float_of_int target_iters *. inter_sleep_s

(* Sentinel used to break out of [Switch.run] once the assertion data is
   collected. Using [Switch.fail] would propagate as the switch's
   failure exception; raising [Exit] is the simpler shape because
   [Switch.run] re-raises and the outer [try] cleans up. *)
exception Test_done

let test_drain_loop_yields_to_co_located_fiber () =
  let counter = ref 0 in
  Eio_main.run @@ fun env ->
    let clock = Eio.Stdenv.clock env in
    let bus = Agent_sdk.Event_bus.create () in
    (try
      Eio.Switch.run (fun sw ->
        KTC.spawn_subscriber ~sw ~clock ~bus;
        for _ = 1 to target_iters do
          Eio.Time.sleep clock inter_sleep_s;
          incr counter
        done;
        raise Test_done)
    with Test_done -> ());
  Alcotest.(check int)
    (Printf.sprintf
       "co-located fiber completed %d sleeps (~%.2fs wall-clock); \
        drain fiber must have yielded"
       target_iters total_expected_wall_clock_s)
    target_iters !counter

let () =
  Alcotest.run "keeper_telemetry_consumer"
    [
      ( "cooperative_scheduling",
        [
          Alcotest.test_case
            "drain loop yields to co-located fiber"
            `Quick
            test_drain_loop_yields_to_co_located_fiber;
        ] );
    ]
